use std::ffi::{CStr, CString, c_char};
use std::ptr;

mod theme_archive;
mod workbook;

/// # Safety
/// The input must remain a valid C string for this call. Release the result with hermes_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hermes_session_params(
    create: bool,
    canonical: bool,
    paged: bool,
    key: *const c_char,
) -> *mut c_char {
    if key.is_null() {
        return ptr::null_mut();
    }
    let Ok(key) = unsafe { CStr::from_ptr(key) }.to_str() else {
        return ptr::null_mut();
    };
    let params = if create {
        hermes_client_core::create(canonical, key)
    } else {
        hermes_client_core::resume(canonical, key, paged)
    };
    CString::new(params.to_string())
        .expect("JSON escapes NUL")
        .into_raw()
}

/// # Safety
/// Pass a live string pointer returned by this library exactly once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hermes_free(result: *mut c_char) {
    if !result.is_null() {
        drop(unsafe { CString::from_raw(result) });
    }
}

/// # Safety
/// The path must point to a valid NUL-terminated UTF-8 string. Release the result with hermes_free.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hermes_workbook_sheet(path: *const c_char, index: u32) -> *mut c_char {
    if path.is_null() {
        return ptr::null_mut();
    }
    let Ok(path) = unsafe { CStr::from_ptr(path) }.to_str() else {
        return ptr::null_mut();
    };
    let value = std::panic::catch_unwind(|| workbook::read(path, index as usize))
        .unwrap_or(Err("invalid"))
        .unwrap_or_else(|error| serde_json::json!({ "error": error }));
    CString::new(value.to_string())
        .expect("JSON escapes NUL")
        .into_raw()
}

/// # Safety
/// The paths are live, NUL-terminated UTF-8 strings for the duration of this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn hermes_theme_archive(
    pack: bool,
    archive: *const c_char,
    directory: *const c_char,
) -> i32 {
    if archive.is_null() || directory.is_null() {
        return 1;
    }
    let Ok(archive) = unsafe { CStr::from_ptr(archive) }.to_str() else {
        return 1;
    };
    let Ok(directory) = unsafe { CStr::from_ptr(directory) }.to_str() else {
        return 1;
    };
    let archive = std::path::Path::new(archive);
    let directory = std::path::Path::new(directory);
    std::panic::catch_unwind(|| {
        if pack {
            theme_archive::pack(archive, directory)
        } else {
            theme_archive::unpack(archive, directory)
        }
    })
    .unwrap_or(Err(1))
    .map_or_else(|error| error, |()| 0)
}
