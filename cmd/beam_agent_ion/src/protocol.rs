//! Exactly the Go frontend's protocol: BE u32 byte length, JSON, fds 3/4.
use serde_json::Value;
use std::io::{self, Read, Write};

pub const MAX_PACKET: usize = 16 * 1024 * 1024;

pub fn read_packet(reader: &mut impl Read) -> io::Result<Value> {
    let mut header = [0; 4];
    reader.read_exact(&mut header)?;
    let size = u32::from_be_bytes(header) as usize;
    if size == 0 || size > MAX_PACKET {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid bridge packet length",
        ));
    }
    let mut bytes = vec![0; size];
    reader.read_exact(&mut bytes)?;
    let value: Value = serde_json::from_slice(&bytes)?;
    if !value.is_object() || !value["type"].is_string() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "packet needs a type",
        ));
    }
    Ok(value)
}

pub fn write_packet(writer: &mut impl Write, packet: &Value) -> io::Result<()> {
    let bytes = serde_json::to_vec(packet)?;
    if bytes.is_empty() || bytes.len() > MAX_PACKET {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "bridge packet too large",
        ));
    }
    writer.write_all(&(bytes.len() as u32).to_be_bytes())?;
    writer.write_all(&bytes)?;
    writer.flush()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn go_compatible_frame_and_consecutive_packets() {
        let packet = json!({"type":"submit","prompt":"Hei 🌍"});
        let mut wire = vec![];
        write_packet(&mut wire, &packet).unwrap();
        assert_eq!(
            u32::from_be_bytes(wire[..4].try_into().unwrap()) as usize,
            wire.len() - 4
        );
        write_packet(&mut wire, &json!({"type":"cancel"})).unwrap();
        let mut reader = &wire[..];
        assert_eq!(read_packet(&mut reader).unwrap(), packet);
        assert_eq!(read_packet(&mut reader).unwrap()["type"], "cancel");
    }
    #[test]
    fn rejects_corruption_and_truncated_frames() {
        for bytes in [
            vec![0, 0, 0, 0],
            vec![255, 255, 255, 255],
            vec![0, 0, 0, 3, b'{'],
            vec![0, 0, 0, 2, b'{', b'}'],
        ] {
            assert!(read_packet(&mut &bytes[..]).is_err());
        }
    }
}
