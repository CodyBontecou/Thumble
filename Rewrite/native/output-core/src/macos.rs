//! Feature-gated dormant macOS adapter, extracted from the retained HID owner.
//! Device creation occurs only through an explicit OutputOwner Activate operation.
use crate::report::{get_report, BAD_ARGUMENT, NO_SPACE, UNSUPPORTED};
use crate::{Device, Factory, Fault, Report, REPORT_DESCRIPTOR, REPORT_ID, REPORT_LENGTH};
use std::sync::atomic::{AtomicBool, Ordering};
const VENDOR_ID: i64 = 0x045e;
const PRODUCT_ID: i64 = 0x028e;
static DEVICE_OWNED: AtomicBool = AtomicBool::new(false);
struct DeviceLease;
impl DeviceLease {
    fn claim() -> Result<Self, Fault> {
        DEVICE_OWNED
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .map_err(|_| Fault::Creation)?;
        Ok(Self)
    }
}
impl Drop for DeviceLease {
    fn drop(&mut self) {
        DEVICE_OWNED.store(false, Ordering::Release);
    }
}
pub struct MacFactory;
impl Factory for MacFactory {
    fn authorization(&mut self) -> Result<(), Fault> {
        match signed_entitlement() {
            Ok(true) => Ok(()),
            Ok(false) => Err(Fault::MissingEntitlement),
            Err(_) => Err(Fault::Creation),
        }
    }
    fn create(&mut self) -> Result<Box<dyn Device>, Fault> {
        let lease = DeviceLease::claim()?;
        OwnedDevice::create(lease)
            .map(|d| Box::new(d) as Box<dyn Device>)
            .map_err(|_| Fault::Creation)
    }
}
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

type GetBlock = RcBlock<dyn Fn(IOHIDReportType, u32, NonNull<u8>, NonNull<isize>) -> i32>;
type SetBlock = RcBlock<dyn Fn(IOHIDReportType, u32, NonNull<u8>, isize) -> i32>;

fn report_blocks(callback_cache: Arc<Mutex<Report>>) -> (GetBlock, SetBlock) {
    let get = RcBlock::new(
        move |kind: IOHIDReportType, id: u32, buffer: NonNull<u8>, length: NonNull<isize>| -> i32 {
            // IOKit supplies valid nonnull pointers for this invocation. Inspect
            // capacity before constructing any buffer reference; no truncation.
            unsafe {
                let capacity = *length.as_ptr();
                *length.as_ptr() = 0;
                if kind != IOHIDReportType::Input || id != u32::from(REPORT_ID) {
                    return UNSUPPORTED as i32;
                }
                if capacity < 0 {
                    return BAD_ARGUMENT as i32;
                }
                if capacity < REPORT_LENGTH as isize {
                    *length.as_ptr() = REPORT_LENGTH as isize;
                    return NO_SPACE as i32;
                }
                // Only the fixed report length is accessed, even if the caller advertises a
                // huge capacity. Cache guard is gone before returning to IOKit.
                let cached = *callback_cache
                    .lock()
                    .unwrap_or_else(|poison| poison.into_inner());
                let buffer = std::slice::from_raw_parts_mut(buffer.as_ptr(), REPORT_LENGTH);
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
    cache: Arc<Mutex<Report>>,
    cancelled: mpsc::Receiver<()>,
    // Retain blocks ourselves too, until all callbacks have completed.
    _get: GetBlock,
    _set: SetBlock,
    _cancel: RcBlock<dyn Fn()>,
    retiring: bool,
    confirmed: bool,
    _lease: DeviceLease,
}

impl OwnedDevice {
    fn create(lease: DeviceLease) -> Result<Self, String> {
        let properties = CFDictionary::from_CFType_pairs(&[
            (
                CFString::new("ReportDescriptor"),
                CFData::from_buffer(REPORT_DESCRIPTOR).as_CFType(),
            ),
            (
                CFString::new("VendorID"),
                CFNumber::from(VENDOR_ID).as_CFType(),
            ),
            (
                CFString::new("ProductID"),
                CFNumber::from(PRODUCT_ID).as_CFType(),
            ),
            (
                CFString::new("VersionNumber"),
                CFNumber::from(1_i64).as_CFType(),
            ),
            (
                CFString::new("SerialNumber"),
                CFString::new("Thumble-Gamepad-2").as_CFType(),
            ),
            (
                CFString::new("PhysicalDeviceUniqueID"),
                CFString::new("Thumble-Gamepad-2").as_CFType(),
            ),
            (
                CFString::new("LocationID"),
                CFNumber::from(0x54485002_i64).as_CFType(),
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
            (CFString::new("Transport"), CFString::new("USB").as_CFType()),
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
        let cache = Arc::new(Mutex::new(Report::NEUTRAL));
        let (get, set) = report_blocks(cache.clone());
        let (notify, cancelled) = mpsc::sync_channel(1);
        let cancel = RcBlock::new(move || {
            let _ = notify.try_send(());
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
            retiring: false,
            confirmed: false,
            _lease: lease,
        })
    }

    // libc's stable Darwin ABI bindings avoid another crate solely for these
    // three Mach clock declarations (deprecated upstream in favor of mach2).
    #[allow(deprecated)]
    fn report(&mut self, mut bytes: [u8; REPORT_LENGTH]) -> (u32, u64) {
        // Never hold the cache lock across a synchronous IOKit call; callbacks
        // can run independently while the owner is blocked in HandleReport.
        *self
            .cache
            .lock()
            .unwrap_or_else(|poison| poison.into_inner()) =
            Report::try_from(bytes).expect("validated output report");
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
                bytes.len() as isize,
            )
        };
        (result as u32, uptime)
    }
}

impl Device for OwnedDevice {
    fn submit(&mut self, report: Report) -> Result<(), Fault> {
        if self.retiring {
            return Err(Fault::Report);
        }
        if self.report(report.bytes()).0 == 0 {
            Ok(())
        } else {
            Err(Fault::Report)
        }
    }
    fn begin_retirement(&mut self) -> Result<(), Fault> {
        if !self.retiring {
            self.device.cancel();
            self.retiring = true;
        }
        Ok(())
    }
    fn retirement_confirmed(&mut self) -> Result<bool, Fault> {
        if self.confirmed {
            return Ok(true);
        }
        if !self.retiring {
            return Ok(false);
        }
        match self.cancelled.try_recv() {
            Ok(()) => {
                // Notification occurs inside the handler; drain its serial queue
                // before dropping device, blocks or any callback-owned resources.
                self.queue.exec_sync(|| {});
                self.confirmed = true;
                Ok(true)
            }
            Err(mpsc::TryRecvError::Empty) => Ok(false),
            Err(mpsc::TryRecvError::Disconnected) => Err(Fault::Cancellation),
        }
    }
}
impl Drop for OwnedDevice {
    fn drop(&mut self) {
        if self.confirmed {
            return;
        }
        if !self.retiring {
            let _ = self.report(Report::NEUTRAL.bytes());
            self.device.cancel();
            self.retiring = true;
        }
        // Emergency unwind still retains CF objects on their owner until the
        // actual callback completes. Caller Drop never joins this thread.
        if self.cancelled.recv().is_err() {
            // Without confirmation, retain the entire context on this detached
            // owner rather than dropping a potentially active CF device.
            loop {
                std::thread::park();
            }
        }
        self.queue.exec_sync(|| {});
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
        let cache = Arc::new(Mutex::new(Report::NEUTRAL));
        let (get, set) = report_blocks(cache.clone());
        for (kind, id, capacity, expected) in [
            (IOHIDReportType::Input, 0, 20, 0),
            (IOHIDReportType::Input, 0, 32, 0),
            (IOHIDReportType::Input, 0, isize::MAX, 0),
            (IOHIDReportType::Input, 0, 19, NO_SPACE),
            (IOHIDReportType::Input, 0, -1, BAD_ARGUMENT),
            (IOHIDReportType::Input, 1, 20, UNSUPPORTED),
            (IOHIDReportType::Input, 2, 20, UNSUPPORTED),
            (IOHIDReportType::Output, 1, 20, UNSUPPORTED),
            (IOHIDReportType::Feature, 1, 20, UNSUPPORTED),
        ] {
            let mut buffer = [0xaa; 32];
            let mut length = capacity;
            let result = get.call((
                kind,
                id,
                NonNull::new(buffer.as_mut_ptr()).unwrap(),
                NonNull::from(&mut length),
            ));
            assert_eq!(result as u32, expected);
            if expected == 0 {
                assert_eq!(length, REPORT_LENGTH as isize);
                assert_eq!(&buffer[..REPORT_LENGTH], &Report::NEUTRAL.bytes());
            } else {
                assert_eq!(
                    length,
                    if expected == NO_SPACE {
                        REPORT_LENGTH as isize
                    } else {
                        0
                    }
                );
                assert_eq!(&buffer[..REPORT_LENGTH], &[0xaa; REPORT_LENGTH]);
            }
            assert_eq!(&buffer[REPORT_LENGTH..], &[0xaa; 12]);
        }
        let mut current = Report::NEUTRAL.bytes();
        current[2] = 1;
        *cache.lock().unwrap() = Report::try_from(current).unwrap();
        let mut buffer = [0; REPORT_LENGTH];
        let mut length = REPORT_LENGTH as isize;
        assert_eq!(
            get.call((
                IOHIDReportType::Input,
                0,
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
        assert_eq!(cache.lock().unwrap().bytes(), current);
    }
}
