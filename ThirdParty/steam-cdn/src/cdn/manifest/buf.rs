use bytes::Buf;
use std::mem::size_of;

use super::error::ManifestError;

pub const MAX_PROTOBUF_MESSAGE: usize = 64 * 1024 * 1024;

pub trait TryBuf: Buf {
    fn try_get_u32(&mut self) -> Result<u32, ManifestError>;
    fn try_get_bytes(&mut self) -> Result<Vec<u8>, ManifestError>;
}

impl<T: Buf> TryBuf for T {
    fn try_get_u32(&mut self) -> Result<u32, ManifestError> {
        if self.remaining() < size_of::<u32>() {
            return Err(ManifestError::Eof("no remaining for u32".to_owned()));
        }

        Ok(self.get_u32_le())
    }

    fn try_get_bytes(&mut self) -> Result<Vec<u8>, ManifestError> {
        let len = self.try_get_u32()? as usize;
        if len > MAX_PROTOBUF_MESSAGE {
            return Err(ManifestError::Eof("protobuf message exceeds 64 MiB".to_owned()));
        }
        if self.remaining() < len {
            return Err(ManifestError::Eof(
                "no remaining for vec of bytes".to_owned(),
            ));
        }

        Ok(self.copy_to_bytes(len).to_vec())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_oversized_frame_before_copy() {
        let too_large = (MAX_PROTOBUF_MESSAGE as u32 + 1).to_le_bytes();
        let mut frame = bytes::Bytes::copy_from_slice(&too_large);
        assert!(frame.try_get_bytes().is_err());
    }
}
