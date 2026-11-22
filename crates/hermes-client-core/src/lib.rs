use serde_json::{Value, json};

pub fn create(canonical: bool, request: &str) -> Value {
    if canonical {
        json!({"source":"gui", "request_id":request})
    } else {
        json!({"source":"desktop", "idempotency_key":request})
    }
}

pub fn resume(canonical: bool, session: &str, paged: bool) -> Value {
    let mut params = json!({"session_id": session});
    if paged {
        params["defer_history"] = json!(true);
        params["omit_messages"] = json!(true);
    }
    if canonical {
        params["display_projection"] = json!(true);
    } else {
        params["source"] = json!("desktop");
    }
    params
}
