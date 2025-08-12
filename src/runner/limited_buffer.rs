pub struct LimitedBuffer {
  buffer: Vec<u8>,
  limit: usize,
}

impl LimitedBuffer {
  pub fn new(limit: usize) -> Self {
    Self {
      buffer: Vec::new(),
      limit,
    }
  }
}

impl AsRef<[u8]> for LimitedBuffer {
  fn as_ref(&self) -> &[u8] {
    &self.buffer
  }
}

impl std::ops::Deref for LimitedBuffer {
  type Target = [u8];

  fn deref(&self) -> &Self::Target {
    &self.buffer
  }
}

impl From<LimitedBuffer> for std::io::Cursor<Vec<u8>> {
  fn from(buffer: LimitedBuffer) -> Self {
    std::io::Cursor::new(buffer.buffer)
  }
}

impl std::io::Write for LimitedBuffer {
  fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
    let len = buf.len();
    if self.buffer.len() + len > self.limit {
      return Err(std::io::Error::new(
        std::io::ErrorKind::FileTooLarge,
        "buffer limit exceeded",
      ));
    }
    self.buffer.extend_from_slice(buf);
    Ok(len)
  }

  fn flush(&mut self) -> std::io::Result<()> {
    Ok(())
  }
}
