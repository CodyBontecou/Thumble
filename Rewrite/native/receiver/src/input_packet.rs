use crate::generated::GamepadState;
use crate::generated_packet::PACKET_BUTTONS;
use aes_gcm::{
    aead::{Aead, KeyInit, Payload},
    Aes256Gcm, Nonce,
};

pub const PACKET_BYTES: usize = 108;
pub const PACKET_LIMIT: u64 = 1 << 20;
const HEADER: usize = 40;
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PacketRejected;

/// Fresh authenticated grant material. Do not persist or recreate senders with the same key.
pub struct PacketGrant {
    cipher: Aes256Gcm,
    session: [u8; 16],
    prefix: [u8; 4],
    generation: u64,
}
impl PacketGrant {
    pub fn new(
        key: &[u8; 32],
        session: [u8; 16],
        prefix: [u8; 4],
        generation: u64,
    ) -> Result<Self, PacketRejected> {
        if session == [0; 16] || generation == 0 {
            return Err(PacketRejected);
        }
        Ok(Self {
            cipher: Aes256Gcm::new_from_slice(key).map_err(|_| PacketRejected)?,
            session,
            prefix,
            generation,
        })
    }
    pub(crate) fn generation(&self) -> u64 {
        self.generation
    }
    pub(crate) fn session(&self) -> [u8; 16] {
        self.session
    }
    fn header(&self, sequence: u64) -> [u8; HEADER] {
        let mut bytes = [0; HEADER];
        bytes[..4].copy_from_slice(b"THI1");
        bytes[8..24].copy_from_slice(&self.session);
        bytes[24..32].copy_from_slice(&self.generation.to_le_bytes());
        bytes[32..40].copy_from_slice(&sequence.to_le_bytes());
        bytes
    }
    fn nonce(&self, sequence: u64) -> [u8; 12] {
        let mut bytes = [0; 12];
        bytes[..4].copy_from_slice(&self.prefix);
        bytes[4..].copy_from_slice(&sequence.to_le_bytes());
        bytes
    }
}
pub struct PacketSender {
    grant: Option<PacketGrant>,
    next: u64,
    limit: u64,
}
impl PacketSender {
    pub fn new(grant: PacketGrant, limit: u64) -> Result<Self, PacketRejected> {
        if !(1..=PACKET_LIMIT).contains(&limit) {
            return Err(PacketRejected);
        }
        Ok(Self {
            grant: Some(grant),
            next: 0,
            limit,
        })
    }
    pub fn close(&mut self) {
        self.grant = None;
    }
    pub fn seal(&mut self, state: &GamepadState) -> Result<Vec<u8>, PacketRejected> {
        let plain = encode_state(state)?;
        if self.next >= self.limit {
            self.close();
            return Err(PacketRejected);
        }
        let grant = self.grant.as_ref().ok_or(PacketRejected)?;
        let sequence = self.next;
        self.next += 1;
        let header = grant.header(sequence);
        let nonce = grant.nonce(sequence);
        let sealed = grant.cipher.encrypt(
            Nonce::from_slice(&nonce),
            Payload {
                msg: &plain,
                aad: &header,
            },
        );
        match sealed {
            Ok(ciphertext) => {
                let mut packet = header.to_vec();
                packet.extend(ciphertext);
                Ok(packet)
            }
            Err(_) => {
                self.close();
                Err(PacketRejected)
            }
        }
    }
}
pub struct PacketReceiver {
    grant: Option<PacketGrant>,
    newest: Option<u64>,
}
impl PacketReceiver {
    pub fn new(grant: PacketGrant) -> Self {
        Self {
            grant: Some(grant),
            newest: None,
        }
    }
    pub fn close(&mut self) {
        self.grant = None;
    }
    pub(crate) fn newest_sequence(&self) -> Option<u64> {
        self.newest
    }
    pub fn open(&mut self, packet: &[u8]) -> Result<GamepadState, PacketRejected> {
        if packet.len() != PACKET_BYTES {
            return Err(PacketRejected);
        }
        let grant = self.grant.as_ref().ok_or(PacketRejected)?;
        let sequence = u64::from_le_bytes(packet[32..40].try_into().map_err(|_| PacketRejected)?);
        if sequence >= PACKET_LIMIT
            || self.newest.is_some_and(|n| sequence <= n)
            || packet[..HEADER] != grant.header(sequence)
        {
            return Err(PacketRejected);
        }
        let nonce = grant.nonce(sequence);
        let plain = grant
            .cipher
            .decrypt(
                Nonce::from_slice(&nonce),
                Payload {
                    msg: &packet[HEADER..],
                    aad: &packet[..HEADER],
                },
            )
            .map_err(|_| PacketRejected)?;
        let state = decode_state(&plain)?;
        self.newest = Some(sequence);
        Ok(state)
    }
}
fn encode_state(state: &GamepadState) -> Result<[u8; 52], PacketRejected> {
    if !state.validate() {
        return Err(PacketRejected);
    }
    let mut mask = 0u32;
    for (i, b) in PACKET_BUTTONS.iter().enumerate() {
        if state.buttons.contains(b) {
            mask |= 1 << i;
        }
    }
    let mut bytes = [0; 52];
    bytes[..4].copy_from_slice(&mask.to_le_bytes());
    for (i, v) in [
        state.left_stick_x,
        state.left_stick_y,
        state.right_stick_x,
        state.right_stick_y,
        state.left_trigger,
        state.right_trigger,
    ]
    .iter()
    .enumerate()
    {
        bytes[4 + i * 8..12 + i * 8].copy_from_slice(&v.to_le_bytes());
    }
    Ok(bytes)
}
fn decode_state(bytes: &[u8]) -> Result<GamepadState, PacketRejected> {
    if bytes.len() != 52 {
        return Err(PacketRejected);
    }
    let mask = u32::from_le_bytes(bytes[..4].try_into().map_err(|_| PacketRejected)?);
    if mask >> 17 != 0 {
        return Err(PacketRejected);
    }
    let mut values = [0.; 6];
    for (i, v) in values.iter_mut().enumerate() {
        *v = f64::from_le_bytes(
            bytes[4 + i * 8..12 + i * 8]
                .try_into()
                .map_err(|_| PacketRejected)?,
        );
    }
    let state = GamepadState {
        buttons: PACKET_BUTTONS
            .iter()
            .enumerate()
            .filter(|(i, _)| mask & (1 << i) != 0)
            .map(|(_, b)| *b)
            .collect(),
        left_stick_x: values[0],
        left_stick_y: values[1],
        right_stick_x: values[2],
        right_stick_y: values[3],
        left_trigger: values[4],
        right_trigger: values[5],
    };
    if !state.validate() {
        return Err(PacketRejected);
    }
    Ok(state)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;
    fn fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../packages/fixtures/input-packet-v1.json"
        ))
        .unwrap()
    }
    fn bytes(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }
    fn grant(f: &Value) -> PacketGrant {
        PacketGrant::new(
            &bytes(f["keyHex"].as_str().unwrap()).try_into().unwrap(),
            bytes(f["sessionHex"].as_str().unwrap()).try_into().unwrap(),
            bytes(f["noncePrefixHex"].as_str().unwrap())
                .try_into()
                .unwrap(),
            f["generation"].as_str().unwrap().parse().unwrap(),
        )
        .unwrap()
    }
    fn packet(f: &Value, index: usize) -> Vec<u8> {
        bytes(f["vectors"][index]["packetHex"].as_str().unwrap())
    }
    #[test]
    fn shared_encrypted_vectors_match_before_quantization() {
        let f = fixture();
        let vectors = f["vectors"].as_array().unwrap();
        assert_eq!(vectors.len(), 33);
        assert_eq!(f["packetBytes"], PACKET_BYTES);
        assert_eq!(f["packetLimit"], PACKET_LIMIT);
        let mut sender = PacketSender::new(grant(&f), PACKET_LIMIT).unwrap();
        let mut receiver = PacketReceiver::new(grant(&f));
        for v in vectors {
            let state: GamepadState = serde_json::from_value(v["state"].clone()).unwrap();
            assert_eq!(
                crate::gamepad::hex(&encode_state(&state).unwrap()),
                v["payloadHex"]
            );
            let sealed = sender.seal(&state).unwrap();
            assert_eq!(crate::gamepad::hex(&sealed), v["packetHex"]);
            let decoded = receiver.open(&sealed).unwrap();
            assert_eq!(
                crate::gamepad::hex(&encode_state(&decoded).unwrap()),
                v["payloadHex"]
            );
            assert_eq!(crate::gamepad::hex(&decoded.report()), v["reportHex"]);
        }
    }
    #[test]
    fn tampering_and_invalid_plaintext_never_advance_counter() {
        let f = fixture();
        let original = packet(&f, 0);
        let mut receiver = PacketReceiver::new(grant(&f));
        for i in 0..original.len() {
            let mut mutated = original.clone();
            mutated[i] ^= 1;
            assert!(receiver.open(&mutated).is_err());
        }
        for v in f["invalidAuthenticated"].as_array().unwrap() {
            assert!(receiver
                .open(&bytes(v["packetHex"].as_str().unwrap()))
                .is_err());
        }
        let mut long = original.clone();
        long.push(0);
        assert!(receiver.open(&long).is_err());
        assert!(receiver.open(&original[..107]).is_err());
        assert!(receiver
            .open(&bytes(f["overLimitPacketHex"].as_str().unwrap()))
            .is_err());
        assert!(receiver.open(&original).is_ok());
    }
    #[test]
    fn replay_reordering_wrong_keys_and_close() {
        let f = fixture();
        let mut r = PacketReceiver::new(grant(&f));
        r.open(&packet(&f, 2)).unwrap();
        for i in 0..3 {
            assert!(r.open(&packet(&f, i)).is_err());
        }
        r.open(&packet(&f, 3)).unwrap();
        r.open(&bytes(f["maximumSequencePacketHex"].as_str().unwrap()))
            .unwrap();
        assert!(r.open(&packet(&f, 4)).is_err());
        r.close();
        r.close();
        assert!(r.open(&packet(&f, 4)).is_err());
        let mut g = grant(&f);
        g.cipher = Aes256Gcm::new_from_slice(&[255; 32]).unwrap();
        assert!(PacketReceiver::new(g).open(&packet(&f, 0)).is_err());
    }
    #[test]
    fn sender_budget_and_invalid_grants_fail_closed() {
        let f = fixture();
        let state: GamepadState = serde_json::from_value(f["vectors"][0]["state"].clone()).unwrap();
        let mut s = PacketSender::new(grant(&f), 2).unwrap();
        s.seal(&state).unwrap();
        s.seal(&state).unwrap();
        assert!(s.seal(&state).is_err());
        assert!(s.seal(&state).is_err());
        let mut s = PacketSender::new(grant(&f), PACKET_LIMIT).unwrap();
        s.close();
        assert!(s.seal(&state).is_err());
        assert!(PacketSender::new(grant(&f), 0).is_err());
        assert!(PacketSender::new(grant(&f), PACKET_LIMIT + 1).is_err());
        assert!(PacketGrant::new(&[0; 32], [0; 16], [0; 4], 1).is_err());
        assert!(PacketGrant::new(&[0; 32], [1; 16], [0; 4], 0).is_err());
    }
}
