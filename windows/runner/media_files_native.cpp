#include <windows.h>

#include <memory>
#include <new>
#include <utility>

namespace {
class ScopedHandle {
 public:
  explicit ScopedHandle(HANDLE handle) : handle_(handle) {}
  ~ScopedHandle() { Close(); }
  ScopedHandle(const ScopedHandle&) = delete;
  ScopedHandle& operator=(const ScopedHandle&) = delete;

  HANDLE get() const { return handle_; }

  DWORD Close() {
    if (handle_ == INVALID_HANDLE_VALUE) return ERROR_SUCCESS;
    const HANDLE handle = std::exchange(handle_, INVALID_HANDLE_VALUE);
    if (!CloseHandle(handle)) return GetLastError();
    return ERROR_SUCCESS;
  }

 private:
  HANDLE handle_;
};
}

struct CopyDetails {
  BOOL source_error;
  BOOL destination_created;
};
static_assert(sizeof(CopyDetails) == 8);

extern "C" __declspec(dllexport) DWORD MediaCopyFileExclusive(
    const wchar_t* source, const wchar_t* destination, CopyDetails* details) {
  *details = {FALSE, FALSE};
  const HANDLE source_handle = CreateFileW(
      source, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
  if (source_handle == INVALID_HANDLE_VALUE) {
    const DWORD error = GetLastError();
    details->source_error = TRUE;
    return error;
  }
  ScopedHandle input(source_handle);

  const HANDLE destination_handle = CreateFileW(
      destination, GENERIC_WRITE, 0, nullptr, CREATE_NEW,
      FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (destination_handle == INVALID_HANDLE_VALUE) return GetLastError();
  ScopedHandle output(destination_handle);
  details->destination_created = TRUE;

  constexpr DWORD kBufferSize = 256 * 1024;
  const std::unique_ptr<BYTE[]> buffer(new (std::nothrow) BYTE[kBufferSize]);
  if (!buffer) return ERROR_NOT_ENOUGH_MEMORY;
  while (true) {
    DWORD count = 0;
    if (!ReadFile(input.get(), buffer.get(), kBufferSize, &count, nullptr)) {
      const DWORD error = GetLastError();
      details->source_error = TRUE;
      return error;
    }
    if (count == 0) break;
    DWORD offset = 0;
    while (offset < count) {
      DWORD written = 0;
      if (!WriteFile(output.get(), buffer.get() + offset, count - offset,
                     &written, nullptr)) {
        return GetLastError();
      }
      if (written == 0) return ERROR_WRITE_FAULT;
      offset += written;
    }
  }
  if (!FlushFileBuffers(output.get())) return GetLastError();
  return output.Close();
}
