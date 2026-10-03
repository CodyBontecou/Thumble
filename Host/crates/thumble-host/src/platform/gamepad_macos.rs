//! IOHID boundary. CF objects and blocks are created, used, and released only
//! on the owned HID worker. Callers exchange owned Rust messages; there is no
//! unsafe Send implementation. Kernel callbacks use a distinct serial queue and
//! an independent ten-byte cache, never the owner/channel/executor lock.
use crate::gamepad::{
    get_report, HidBackend, BAD_ARGUMENT, NEUTRAL_REPORT, NO_SPACE, REPORT_DESCRIPTOR, UNSUPPORTED,
};
use block2::RcBlock;
use core_foundation::{
    base::{CFType, CFTypeRef, TCFType},
    boolean::{kCFBooleanTrue, CFBooleanGetTypeID},
    data::CFData,
    dictionary::CFDictionary,
    number::CFNumber,
    string::{CFString, CFStringRef},
};
use dispatch2::{DispatchQueue, DispatchRetained};
use objc2_core_foundation::CFRetained;
use objc2_io_kit::{IOHIDReportType, IOHIDUserDevice, IOHIDUserDeviceOptions};
use std::{
    ffi::c_void,
    ptr::NonNull,
    sync::{mpsc, Arc, Mutex},
    thread,
    time::Duration,
};

#[link(name = "Security", kind = "framework")]
extern "C" {
    fn SecTaskCreateFromSelf(allocator: *const c_void) -> CFTypeRef;
    fn SecTaskCopyValueForEntitlement(
        task: CFTypeRef,
        entitlement: CFStringRef,
        error: *mut CFTypeRef,
    ) -> CFTypeRef;
}

fn signed_entitlement() -> Result<bool, String> {
    // SecTask reads the executing process's signed entitlement claim, not an
    // unsigned plist/profile or the caller's supplied configuration.
    unsafe {
        let task = SecTaskCreateFromSelf(std::ptr::null());
        if task.is_null() {
            return Err("SecTaskCreateFromSelf failed; signed HID claim is unknown".into());
        }
        let task = CFType::wrap_under_create_rule(task);
        let key = CFString::new("com.apple.developer.hid.virtual.device");
        let mut error = std::ptr::null();
        let value = SecTaskCopyValueForEntitlement(
            task.as_CFTypeRef(),
            key.as_concrete_TypeRef(),
            &mut error,
        );
        if !error.is_null() {
            let _error = CFType::wrap_under_create_rule(error);
            if !value.is_null() {
                let _value = CFType::wrap_under_create_rule(value);
            }
            return Err("Security could not inspect the receiver's signed HID claim".into());
        }
        if value.is_null() {
            return Ok(false);
        }
        let value = CFType::wrap_under_create_rule(value);
        // Require an actual Boolean true, not a string or numeric lookalike.
        Ok(is_boolean_true(&value))
    }
}

fn is_boolean_true(value: &CFType) -> bool {
    unsafe {
        value.type_of() == CFBooleanGetTypeID() && value.as_CFTypeRef() == kCFBooleanTrue.cast()
    }
}

enum Command {
    Entitlement(mpsc::SyncSender<Result<bool, String>>),
    Start(mpsc::SyncSender<Result<(), String>>),
    Report([u8; 10], mpsc::SyncSender<Result<(u32, u64), String>>),
    Stop(mpsc::SyncSender<()>),
    Shutdown,
}

/// Send follows from Sender/JoinHandle and owned strings; no CF pointer escapes.
pub(crate) struct MacHidBackend {
    sender: Option<mpsc::SyncSender<Command>>,
    worker: Option<thread::JoinHandle<()>>,
    spawn_error: Option<String>,
}

impl MacHidBackend {
    pub(crate) fn new() -> Self {
        let (sender, receiver) = mpsc::sync_channel(8);
        match thread::Builder::new()
            .name("thumble-hid-owner".into())
            .spawn(move || worker_loop(receiver))
        {
            Ok(worker) => Self {
                sender: Some(sender),
                worker: Some(worker),
                spawn_error: None,
            },
            Err(error) => Self {
                sender: None,
                worker: None,
                spawn_error: Some(format!("Cannot start HID owner: {error}")),
            },
        }
    }

    fn request<T>(
        &self,
        command: impl FnOnce(mpsc::SyncSender<T>) -> Command,
        timeout: Duration,
    ) -> Result<T, String> {
        let sender = self.sender.as_ref().ok_or_else(|| {
            self.spawn_error
                .clone()
                .unwrap_or_else(|| "HID owner stopped".into())
        })?;
        let (reply, receiver) = mpsc::sync_channel(1);
        sender.try_send(command(reply)).map_err(|_| {
            "HID owner unavailable or busy; prior operation/retirement may still be pending"
                .to_string()
        })?;
        receiver
            .recv_timeout(timeout)
            .map_err(|_| "HID owner did not acknowledge in time; device remains owned and retirement may be pending".to_string())
    }
}

impl HidBackend for MacHidBackend {
    fn entitlement(&mut self) -> Result<bool, String> {
        self.request(Command::Entitlement, Duration::from_secs(1))?
    }
    fn start(&mut self) -> Result<(), String> {
        self.request(Command::Start, Duration::from_secs(1))?
    }
    fn report(&mut self, bytes: [u8; 10]) -> Result<(u32, u64), String> {
        self.request(
            |reply| Command::Report(bytes, reply),
            Duration::from_millis(100),
        )?
    }
    fn stop(&mut self) {
        let _ = self.request(Command::Stop, Duration::from_millis(100));
    }
}

impl Drop for MacHidBackend {
    fn drop(&mut self) {
        if let Some(sender) = self.sender.take() {
            let _ = sender.try_send(Command::Shutdown);
        }
        if let Some(worker) = self.worker.take() {
            // A stalled OS cancel must not block keyboard/pointer release or
            // shutdown. Detach, never release its CF objects from this caller.
            // The worker retains the sole device through eventual completion.
            drop(worker);
        }
    }
}

fn worker_loop(receiver: mpsc::Receiver<Command>) {
    // This local contains all !Send objects and is never captured by a message.
    let mut device: Option<OwnedDevice> = None;
    while let Ok(command) = receiver.recv() {
        match command {
            Command::Entitlement(reply) => {
                let _ = reply.send(signed_entitlement());
            }
            Command::Start(reply) => {
                // Start is serialized after synchronous retirement; never overlap.
                let result = if device.is_some() {
                    Err("HID device already exists".into())
                } else {
                    OwnedDevice::create().map(|created| {
                        device = Some(created);
                    })
                };
                let _ = reply.send(result);
            }
            Command::Report(bytes, reply) => {
                let result = device
                    .as_mut()
                    .ok_or_else(|| "No HID device exists".into())
                    .map(|device| device.report(bytes));
                let _ = reply.send(result);
            }
            Command::Stop(reply) => {
                drop(device.take()); // Drop neutralizes and waits for cancel completion.
                let _ = reply.send(());
            }
            Command::Shutdown => break,
        }
    }
    drop(device);
}

type GetBlock = RcBlock<dyn Fn(IOHIDReportType, u32, NonNull<u8>, NonNull<isize>) -> i32>;
type SetBlock = RcBlock<dyn Fn(IOHIDReportType, u32, NonNull<u8>, isize) -> i32>;

fn report_blocks(callback_cache: Arc<Mutex<[u8; 10]>>) -> (GetBlock, SetBlock) {
    let get = RcBlock::new(
        move |kind: IOHIDReportType, id: u32, buffer: NonNull<u8>, length: NonNull<isize>| -> i32 {
            // IOKit supplies valid nonnull pointers for this invocation. Inspect
            // capacity before constructing any buffer reference; no truncation.
            unsafe {
                let capacity = *length.as_ptr();
                *length.as_ptr() = 0;
                if kind != IOHIDReportType::Input || id != 1 {
                    return UNSUPPORTED as i32;
                }
                if capacity < 0 {
                    return BAD_ARGUMENT as i32;
                }
                if capacity < 10 {
                    *length.as_ptr() = 10;
                    return NO_SPACE as i32;
                }
                // Only ten bytes are accessed, even if the caller advertises a
                // huge capacity. Cache guard is gone before returning to IOKit.
                let cached = *callback_cache
                    .lock()
                    .unwrap_or_else(|poison| poison.into_inner());
                let buffer = std::slice::from_raw_parts_mut(buffer.as_ptr(), 10);
                match get_report(cached, kind.0, id, buffer) {
                    Ok(count) => {
                        *length.as_ptr() = count as isize;
                        0
                    }
                    Err(error) => error as i32,
                }
            }
        },
    );
    let set = RcBlock::new(
        |_kind: IOHIDReportType, _id: u32, _buffer: NonNull<u8>, _length: isize| -> i32 {
            UNSUPPORTED as i32
        },
    );
    (get, set)
}

struct OwnedDevice {
    device: CFRetained<IOHIDUserDevice>,
    queue: DispatchRetained<DispatchQueue>,
    cache: Arc<Mutex<[u8; 10]>>,
    cancelled: mpsc::Receiver<()>,
    // Retain blocks ourselves too, until all callbacks have completed.
    _get: GetBlock,
    _set: SetBlock,
    _cancel: RcBlock<dyn Fn()>,
}

impl OwnedDevice {
    fn create() -> Result<Self, String> {
        let properties = CFDictionary::from_CFType_pairs(&[
            (
                CFString::new("ReportDescriptor"),
                CFData::from_buffer(REPORT_DESCRIPTOR).as_CFType(),
            ),
            (
                CFString::new("VendorID"),
                CFNumber::from(0xcb01_i64).as_CFType(),
            ),
            (
                CFString::new("ProductID"),
                CFNumber::from(0x5050_i64).as_CFType(),
            ),
            (
                CFString::new("VersionNumber"),
                CFNumber::from(1_i64).as_CFType(),
            ),
            (
                CFString::new("SerialNumber"),
                CFString::new("PocketPad-Gamepad-1").as_CFType(),
            ),
            (
                CFString::new("PrimaryUsagePage"),
                CFNumber::from(1_i64).as_CFType(),
            ),
            (
                CFString::new("PrimaryUsage"),
                CFNumber::from(5_i64).as_CFType(),
            ),
            (
                CFString::new("Product"),
                CFString::new("Thumble Virtual Gamepad").as_CFType(),
            ),
            (
                CFString::new("Manufacturer"),
                CFString::new("Thumble").as_CFType(),
            ),
            (
                CFString::new("Transport"),
                CFString::new("Virtual").as_CFType(),
            ),
        ]);
        // Both wrappers refer to the same CoreFoundation ABI object. The borrow
        // stays within properties' lifetime; its keys/values are valid CF types.
        let properties_ref = unsafe {
            &*properties
                .as_concrete_TypeRef()
                .cast::<objc2_core_foundation::CFDictionary>()
        };
        let device = unsafe { IOHIDUserDevice::with_properties(None, properties_ref, IOHIDUserDeviceOptions::CreateOnActivate.0) }
            .ok_or_else(|| "IOHIDUserDevice creation failed despite signed entitlement claim; check provisioning and OS authorization".to_string())?;
        let queue = DispatchQueue::new("com.thumble.hid.callbacks", None);
        let cache = Arc::new(Mutex::new(NEUTRAL_REPORT));
        let (get, set) = report_blocks(cache.clone());
        let (notify, cancelled) = mpsc::sync_channel(1);
        let cancel = RcBlock::new(move || {
            let _ = notify.send(());
        });
        // All registration precedes activation. Blocks capture only Send Rust
        // data, and never the CF device itself or the owner's command channel.
        unsafe {
            device.register_get_report_block(RcBlock::as_ptr(&get));
            device.register_set_report_block(RcBlock::as_ptr(&set));
            device.set_dispatch_queue(&queue);
            device.set_cancel_handler(RcBlock::as_ptr(&cancel));
        }
        device.activate();
        Ok(Self {
            device,
            queue,
            cache,
            cancelled,
            _get: get,
            _set: set,
            _cancel: cancel,
        })
    }

    // libc's stable Darwin ABI bindings avoid another crate solely for these
    // three Mach clock declarations (deprecated upstream in favor of mach2).
    #[allow(deprecated)]
    fn report(&mut self, mut bytes: [u8; 10]) -> (u32, u64) {
        // Never hold the cache lock across a synchronous IOKit call; callbacks
        // can run independently while the owner is blocked in HandleReport.
        *self
            .cache
            .lock()
            .unwrap_or_else(|poison| poison.into_inner()) = bytes;
        let ticks = unsafe { libc::mach_absolute_time() };
        let mut timebase = libc::mach_timebase_info { numer: 0, denom: 0 };
        unsafe {
            libc::mach_timebase_info(&mut timebase);
        }
        let uptime = if timebase.denom == 0 {
            0
        } else {
            ((u128::from(ticks) * u128::from(timebase.numer)) / u128::from(timebase.denom))
                .min(u128::from(u64::MAX)) as u64
        };
        let result = unsafe {
            self.device.handle_report_with_time_stamp(
                ticks,
                NonNull::new(bytes.as_mut_ptr()).unwrap(),
                10,
            )
        };
        (result as u32, uptime)
    }
}

/// Keep the retirement sequence testable without creating an OS device.
trait RetirableDevice {
    fn neutralize(&mut self);
    fn cancel(&mut self);
    fn wait_for_cancel(&mut self);
}

fn retire_device(device: &mut impl RetirableDevice) {
    device.neutralize();
    device.cancel();
    device.wait_for_cancel();
}

impl RetirableDevice for OwnedDevice {
    fn neutralize(&mut self) {
        let _ = self.report(NEUTRAL_REPORT); // Best effort, including after failure.
    }

    fn cancel(&mut self) {
        self.device.cancel();
    }

    fn wait_for_cancel(&mut self) {
        // Keep device, queue, cache and blocks retained through cancellation.
        // There is deliberately no timeout that could release a live device or
        // permit overlap. Waiting occurs only on the owner, not callback queue.
        let _ = self.cancelled.recv();
        // Notification was sent inside the handler; drain the serial queue so
        // the handler has actually returned before releasing captured objects.
        self.queue.exec_sync(|| {});
    }
}

impl Drop for OwnedDevice {
    fn drop(&mut self) {
        retire_device(self);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn retirement_retains_device_until_cancel_completion() {
        use std::time::Duration;
        struct FakeDevice {
            events: Arc<Mutex<Vec<&'static str>>>,
            notify: mpsc::SyncSender<()>,
            completion: mpsc::Receiver<()>,
        }
        impl RetirableDevice for FakeDevice {
            fn neutralize(&mut self) {
                self.events.lock().unwrap().push("neutral");
            }
            fn cancel(&mut self) {
                self.events.lock().unwrap().push("cancel");
                self.notify.send(()).unwrap();
            }
            fn wait_for_cancel(&mut self) {
                self.completion
                    .recv_timeout(Duration::from_secs(5))
                    .unwrap();
                self.events.lock().unwrap().push("cancel-complete");
            }
        }
        impl Drop for FakeDevice {
            fn drop(&mut self) {
                retire_device(self);
                self.events.lock().unwrap().push("release");
            }
        }
        let events = Arc::new(Mutex::new(vec![]));
        let owner_events = events.clone();
        let (notify, cancelling) = mpsc::sync_channel(1);
        let (complete, completion) = mpsc::sync_channel(1);
        let owner = thread::spawn(move || {
            let device = FakeDevice {
                events: owner_events,
                notify,
                completion,
            };
            drop(device);
        });
        cancelling.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(*events.lock().unwrap(), ["neutral", "cancel"]);
        // Retirement is still blocked, so neither release nor a subsequent
        // serial-owner creation can occur until the completion notification.
        complete.send(()).unwrap();
        owner.join().unwrap();
        assert_eq!(
            *events.lock().unwrap(),
            ["neutral", "cancel", "cancel-complete", "release"]
        );
    }

    #[test]
    fn entitlement_requires_boolean_true() {
        use core_foundation::boolean::CFBoolean;
        assert!(is_boolean_true(&CFBoolean::true_value().as_CFType()));
        assert!(!is_boolean_true(&CFBoolean::false_value().as_CFType()));
        assert!(!is_boolean_true(&CFNumber::from(1_i64).as_CFType()));
        assert!(!is_boolean_true(&CFString::new("true").as_CFType()));
    }

    #[test]
    fn ffi_callback_blocks_validate_and_return_current_cache() {
        let cache = Arc::new(Mutex::new(NEUTRAL_REPORT));
        let (get, set) = report_blocks(cache.clone());
        for (kind, id, capacity, expected) in [
            (IOHIDReportType::Input, 1, 10, 0),
            (IOHIDReportType::Input, 1, 20, 0),
            (IOHIDReportType::Input, 1, isize::MAX, 0),
            (IOHIDReportType::Input, 1, 9, NO_SPACE),
            (IOHIDReportType::Input, 1, -1, BAD_ARGUMENT),
            (IOHIDReportType::Input, 0, 20, UNSUPPORTED),
            (IOHIDReportType::Input, 2, 20, UNSUPPORTED),
            (IOHIDReportType::Output, 1, 20, UNSUPPORTED),
            (IOHIDReportType::Feature, 1, 20, UNSUPPORTED),
        ] {
            let mut buffer = [0xaa; 20];
            let mut length = capacity;
            let result = get.call((
                kind,
                id,
                NonNull::new(buffer.as_mut_ptr()).unwrap(),
                NonNull::from(&mut length),
            ));
            assert_eq!(result as u32, expected);
            if expected == 0 {
                assert_eq!(length, 10);
                assert_eq!(&buffer[..10], &NEUTRAL_REPORT);
            } else {
                assert_eq!(length, if expected == NO_SPACE { 10 } else { 0 });
                assert_eq!(&buffer[..10], &[0xaa; 10]);
            }
            assert_eq!(&buffer[10..], &[0xaa; 10]);
        }
        let mut current = NEUTRAL_REPORT;
        current[1] = 1;
        *cache.lock().unwrap() = current;
        let mut buffer = [0; 10];
        let mut length = 10;
        assert_eq!(
            get.call((
                IOHIDReportType::Input,
                1,
                NonNull::new(buffer.as_mut_ptr()).unwrap(),
                NonNull::from(&mut length)
            )),
            0
        );
        assert_eq!(buffer, current);
        for kind in [
            IOHIDReportType::Input,
            IOHIDReportType::Output,
            IOHIDReportType::Feature,
        ] {
            assert_eq!(
                set.call((kind, 1, NonNull::new(buffer.as_mut_ptr()).unwrap(), 10)) as u32,
                UNSUPPORTED
            );
        }
        assert_eq!(*cache.lock().unwrap(), current);
    }

    #[test]
    fn stalled_owner_report_stop_and_drop_are_bounded_and_queue_saturation_fails_closed() {
        let (sender, receiver) = mpsc::sync_channel(8);
        let mut backend = MacHidBackend {
            sender: Some(sender.clone()),
            worker: None,
            spawn_error: None,
        };
        let began = std::time::Instant::now();
        assert!(backend
            .report(NEUTRAL_REPORT)
            .unwrap_err()
            .contains("did not acknowledge"));
        backend.stop();
        assert!(began.elapsed() < Duration::from_secs(2));
        // Leave commands pending in the fake OS-owner channel; no HID is created.
        for _ in 0..6 {
            sender.try_send(Command::Shutdown).unwrap();
        }
        let began = std::time::Instant::now();
        assert!(backend
            .report(NEUTRAL_REPORT)
            .unwrap_err()
            .contains("unavailable or busy"));
        drop(backend);
        assert!(began.elapsed() < Duration::from_secs(1));
        drop(receiver);
    }

    #[test]
    fn worker_handle_is_send_without_cf_send() {
        fn assert_send<T: Send>() {}
        assert_send::<MacHidBackend>();
        // No worker request or OS creation is needed to verify the type boundary.
    }

    #[test]
    fn recording_never_instantiates_worker() {
        let mut output = crate::gamepad::GamepadOutput::new(false);
        output.set_enabled(true).unwrap();
        output.reset().unwrap();
        output.retry().unwrap();
        assert_eq!(output.snapshot().phase, "recording");
        assert_eq!(output.snapshot().entitlement_granted, None);
    }
}
