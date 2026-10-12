// SPDX-License-Identifier: MPL-2.0
//! Durable library storage. The schema, WAL policy and revision ordering stay
//! compatible with existing Neutrino data; Swift only supplies Codable bytes.
use rusqlite::{Connection, OpenFlags, OptionalExtension, TransactionBehavior};
use std::{
    ffi::{c_char, CStr, CString},
    path::Path,
    sync::Mutex,
    time::Duration,
};
const MAX_LIBRARY: usize = 64 * 1024 * 1024;
pub struct Library {
    connection: Connection,
    revision: u64,
}
pub struct Database(Mutex<Library>);
impl Library {
    fn open(path: &str) -> Result<Self, String> {
        let path = Path::new(path);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        let connection = Connection::open_with_flags(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_CREATE
                | OpenFlags::SQLITE_OPEN_FULL_MUTEX,
        )
        .map_err(|e| e.to_string())?;
        connection
            .busy_timeout(Duration::from_secs(5))
            .map_err(|e| e.to_string())?;
        let version: i64 = connection
            .query_row("PRAGMA user_version", [], |r| r.get(0))
            .map_err(|e| e.to_string())?;
        if version > 1 {
            return Err(
                "Your Neutrino data was created by a newer version. It has not been changed."
                    .into(),
            );
        }
        connection.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS library(id INTEGER PRIMARY KEY CHECK(id=1),data BLOB NOT NULL); PRAGMA user_version=1;").map_err(|e|e.to_string())?;
        Ok(Self {
            connection,
            revision: 0,
        })
    }
    fn load(&self) -> Result<Option<Vec<u8>>, String> {
        let count: Option<i64> = self
            .connection
            .query_row("SELECT length(data) FROM library WHERE id=1", [], |r| {
                r.get(0)
            })
            .optional()
            .map_err(|e| e.to_string())?;
        match count {
            None => Ok(None),
            Some(n) if n < 0 || n as usize > MAX_LIBRARY => {
                Err("Neutrino data exceeds the supported size. Use recovery to export it.".into())
            }
            _ => self
                .connection
                .query_row("SELECT data FROM library WHERE id=1", [], |r| r.get(0))
                .optional()
                .map_err(|e| e.to_string()),
        }
    }
    fn save(&mut self, data: &[u8], revision: u64) -> Result<(), String> {
        if revision < self.revision {
            return Ok(());
        }
        if data.len() > MAX_LIBRARY {
            return Err(
                "Neutrino data is too large to save. Export or remove older notes and bookmarks."
                    .into(),
            );
        }
        // An interrupted transaction rolls back when its guard is dropped.
        let transaction = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(|e| e.to_string())?;
        transaction.execute("INSERT INTO library(id,data) VALUES(1,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",[data]).map_err(|e|e.to_string())?;
        transaction.commit().map_err(|e| e.to_string())?;
        self.revision = revision;
        Ok(())
    }
}
fn owned(message: String) -> *mut c_char {
    CString::new(message.replace('\0', "�")).unwrap().into_raw()
}
unsafe fn error(target: *mut *mut c_char, message: String) {
    if !target.is_null() {
        *target = owned(message);
    }
}
/// # Safety
/// Valid NUL-terminated path and writable error pointer; free returned handle once.
#[no_mangle]
pub unsafe extern "C" fn neutrino_database_open(
    path: *const c_char,
    out_error: *mut *mut c_char,
) -> *mut Database {
    if !out_error.is_null() {
        *out_error = std::ptr::null_mut();
    }
    let result = std::panic::catch_unwind(|| {
        if path.is_null() {
            return Err("Missing database path".into());
        }
        let path = CStr::from_ptr(path).to_str().map_err(|e| e.to_string())?;
        Library::open(path)
    });
    match result {
        Ok(Ok(db)) => Box::into_raw(Box::new(Database(Mutex::new(db)))),
        Ok(Err(e)) => {
            error(out_error, e);
            std::ptr::null_mut()
        }
        Err(_) => {
            error(out_error, "Could not open library".into());
            std::ptr::null_mut()
        }
    }
}
/// # Safety
/// Handle must be live, uniquely freed and unused by any concurrent call.
#[no_mangle]
pub unsafe extern "C" fn neutrino_database_free(handle: *mut Database) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}
/// # Safety
/// Live handle and writable error pointer. Returned JSON is owned; use string_free.
#[no_mangle]
pub unsafe extern "C" fn neutrino_database_load(
    handle: *mut Database,
    out_error: *mut *mut c_char,
) -> *mut c_char {
    if !out_error.is_null() {
        *out_error = std::ptr::null_mut();
    }
    let result = std::panic::catch_unwind(|| {
        let db = handle
            .as_ref()
            .ok_or("Missing database")?
            .0
            .lock()
            .map_err(|_| "Library lock failed")?;
        db.load()?
            .map(|bytes| {
                if bytes.contains(&0) { return Err("The library contains invalid JSON bytes. Its data has not been changed.".into()); }
                String::from_utf8(bytes).map_err(|e| e.to_string())
            })
            .transpose()
    });
    match result {
        Ok(Ok(Some(data))) => owned(data),
        Ok(Ok(None)) => std::ptr::null_mut(),
        Ok(Err(e)) => {
            error(out_error, e);
            std::ptr::null_mut()
        }
        Err(_) => {
            error(out_error, "Could not read library".into());
            std::ptr::null_mut()
        }
    }
}
/// # Safety
/// Handle must be live; data must point to `length` readable bytes for this call.
/// Returns null on success or an owned error to release with string_free.
#[no_mangle]
pub unsafe extern "C" fn neutrino_database_save(
    handle: *mut Database,
    data: *const u8,
    length: usize,
    revision: u64,
) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if length > MAX_LIBRARY || data.is_null() {
            return Err("Library data is invalid or too large.".to_string());
        }
        let mut db = handle
            .as_ref()
            .ok_or("Missing database")?
            .0
            .lock()
            .map_err(|_| "Library lock failed")?;
        db.save(std::slice::from_raw_parts(data, length), revision)
    });
    match result {
        Ok(Ok(())) => std::ptr::null_mut(),
        Ok(Err(e)) => owned(e),
        Err(_) => owned("Could not save library".into()),
    }
}
/// # Safety
/// Handle must remain live for the call; free a nonnull returned error string.
#[no_mangle]
pub unsafe extern "C" fn neutrino_database_checkpoint(handle: *mut Database) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        let db = handle
            .as_ref()
            .ok_or("Missing database")?
            .0
            .lock()
            .map_err(|_| "Library lock failed")?;
        let busy: i64 = db
            .connection
            .query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |r| r.get(0))
            .map_err(|e| e.to_string())?;
        if busy != 0 {
            return Err("The library is busy. Retry saving before replacing the app.".to_string());
        }
        Ok(())
    });
    match result {
        Ok(Ok(())) => std::ptr::null_mut(),
        Ok(Err(e)) => owned(e),
        Err(_) => owned("Could not checkpoint library".into()),
    }
}
