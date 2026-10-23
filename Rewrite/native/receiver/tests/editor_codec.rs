#[path = "../src/editor_codec.rs"]
mod editor_codec;
use editor_codec::{Context, Operation, Reply, Request};
use serde_json::{json, Value};
fn vectors() -> Value {
    serde_json::from_str(include_str!(
        "../../../packages/fixtures/phone-editor-control-v1.json"
    ))
    .unwrap()
}
fn context() -> Context {
    let v = vectors();
    Context {
        connection_id: v["context"]["connectionId"].as_str().unwrap().into(),
        authority_instance_id: v["context"]["authorityInstanceId"].as_str().unwrap().into(),
    }
}
fn bytes(v: &Value) -> Vec<u8> {
    serde_json::to_vec(v).unwrap()
}
fn write() -> Value {
    vectors()["cases"][1]["request"].clone()
}
fn profile() -> Value {
    vectors()["cases"][0]["request"].clone()
}
#[test]
fn shared_vectors_preserve_all_success_error_pending_and_unicode_variants() {
    for c in vectors()["cases"].as_array().unwrap() {
        let request = Request::parse(&bytes(&c["request"]), &context())
            .unwrap_or_else(|_| panic!("request {}", c["name"]));
        let reply = Reply::parse(&bytes(&c["reply"]), &request)
            .unwrap_or_else(|_| panic!("reply {}", c["name"]));
        assert_eq!(reply.kind, c["reply"]["kind"].as_str().unwrap());
        assert_eq!(reply.value, c["reply"]);
    }
    let mut v = write();
    v["label"] = Value::Null;
    assert!(
        matches!(Request::parse(&bytes(&v),&context()).unwrap().operation,Operation::SetLabel(i) if i.label.is_none())
    );
    v["label"] = "".into();
    assert!(
        matches!(Request::parse(&bytes(&v),&context()).unwrap().operation,Operation::SetLabel(i) if i.label==Some(String::new()))
    );
}
#[test]
fn recursive_duplicates_unknowns_private_fields_and_malformed_unicode_reject() {
    let original = String::from_utf8(bytes(&write())).unwrap();
    for text in [
        original.replacen("\"version\":1", "\"version\":1,\"version\":1", 1),
        original.replacen("\"label\":\"Move 🦊\"", "\"label\":\"\\ud800\"", 1),
        original + " false",
    ] {
        assert!(Request::parse(text.as_bytes(), &context()).is_err());
    }
    let status = vectors()["cases"][5]["request"].clone();
    let text = String::from_utf8(bytes(&status)).unwrap().replacen(
        "\"expectedRevision\":\"7\"",
        "\"expectedRevision\":\"7\",\"expectedRevision\":\"7\"",
        1,
    );
    assert!(Request::parse(text.as_bytes(), &context()).is_err());
    for key in [
        "ownerLifetimeId",
        "phoneId",
        "credentialEpoch",
        "eventId",
        "path",
        "source",
        "output",
        "generation",
        "unexpected",
    ] {
        let mut v = write();
        v[key] = "injected".into();
        assert!(Request::parse(&bytes(&v), &context()).is_err());
        let mut v = status.clone();
        v["intent"][key] = "injected".into();
        assert!(Request::parse(&bytes(&v), &context()).is_err());
    }
    let mut invalid = bytes(&write());
    invalid.push(0xff);
    assert!(Request::parse(&invalid, &context()).is_err());
}
#[test]
fn identity_counter_command_context_and_request_bounds_are_strict() {
    for (key, value) in [
        ("expectedRevision", json!(7)),
        ("expectedRevision", json!("07")),
        ("expectedRevision", json!("18446744073709551616")),
        ("profileId", json!("AAAAAAAA-0000-0000-0000-000000000001")),
        ("operationId", json!("bad_id")),
        ("label", json!("🦊".repeat(33))),
        ("label", json!(false)),
        ("command", json!("configuration-delete-profile")),
        (
            "authorityInstanceId",
            json!("22222222-2222-2222-2222-222222222222"),
        ),
        ("connectionId", json!("cd".repeat(16))),
    ] {
        let mut v = write();
        v[key] = value;
        assert!(Request::parse(&bytes(&v), &context()).is_err(), "{key}");
    }
    for offset in [json!(-1), json!(1), json!(128), json!("0"), json!(0.0)] {
        let mut v = profile();
        v["offset"] = offset;
        assert!(Request::parse(&bytes(&v), &context()).is_err());
    }
    assert!(Request::parse(&vec![b' '; editor_codec::REQUEST_BYTES + 1], &context()).is_err());
    for field in write().as_object().unwrap().keys() {
        let mut v = write();
        v.as_object_mut().unwrap().remove(field);
        assert!(Request::parse(&bytes(&v), &context()).is_err());
    }
}
#[test]
fn receipts_are_exact_and_pending_admission_are_command_specific() {
    let v = vectors();
    let req = Request::parse(&bytes(&write()), &context()).unwrap();
    let valid = v["cases"][2]["reply"].clone();
    for (key, value) in [
        ("operationId", json!("other")),
        ("resultingRevision", json!("9")),
        ("resultingRevision", json!("08")),
        (
            "affectedEntities",
            json!(["aaaaaaaa-0000-0000-0000-000000000001", "other"]),
        ),
        ("contentHash", json!("A".repeat(64))),
    ] {
        let mut x = valid.clone();
        x["receipt"][key] = value;
        assert!(Reply::parse(&bytes(&x), &req).is_err());
    }
    let text = String::from_utf8(bytes(&valid)).unwrap().replacen(
        "\"version\":1",
        "\"version\":1,\"version\":1",
        1,
    );
    assert!(Reply::parse(text.as_bytes(), &req).is_err());
    let status = Request::parse(&bytes(&v["cases"][5]["request"]), &context()).unwrap();
    assert!(Reply::parse(&bytes(&v["cases"][1]["reply"]), &status).is_err());
    assert!(Reply::parse(&bytes(&v["cases"][5]["reply"]), &req).is_err());
    let mut max = write();
    max["expectedRevision"] = "18446744073709551615".into();
    let max = Request::parse(&bytes(&max), &context()).unwrap();
    assert!(Reply::parse(&bytes(&valid), &max).is_err());
}
#[test]
fn profile_page_echo_array_fields_and_all_escaped_maximum_fit_whole_frame() {
    let v = vectors();
    let mut request = profile();
    request["expectedRevision"] = "18446744073709551615".into();
    request["offset"] = 120.into();
    let request = Request::parse(&bytes(&request), &context()).unwrap();
    let mut page = v["cases"][0]["reply"].clone();
    page["revision"] = "18446744073709551615".into();
    page["offset"] = 120.into();
    page["totalControls"] = 128.into();
    page["nextOffset"] = Value::Null;
    page["name"] = "\0".repeat(256).into();
    for c in page["controls"].as_array_mut().unwrap() {
        c["generatedLabel"] = "\0".repeat(128).into();
        c["labelOverride"] = "\0".repeat(128).into();
    }
    let encoded = bytes(&page);
    assert!(encoded.len() < editor_codec::REPLY_BYTES);
    assert!(Reply::parse(&encoded, &request).is_ok());
    for (key, value) in [
        ("revision", json!("1")),
        ("contentHash", json!("f".repeat(64))),
        ("offset", json!(0)),
        ("totalControls", json!(129)),
        ("nextOffset", json!(128)),
        ("name", json!("\u{feff}".repeat(256))),
    ] {
        let mut x = page.clone();
        x[key] = value;
        assert!(Reply::parse(&bytes(&x), &request).is_err());
    }
    let mut x = page.clone();
    x["controls"][1]["id"] = x["controls"][0]["id"].clone();
    assert!(Reply::parse(&bytes(&x), &request).is_err());
    let mut x = page.clone();
    x["controls"][0]["unknown"] = "private".into();
    assert!(Reply::parse(&bytes(&x), &request).is_err());
    let raw = String::from_utf8(encoded).unwrap();
    let duplicate = raw.replacen(
        "\"generatedLabel\":",
        "\"generatedLabel\":\"duplicate\",\"generatedLabel\":",
        1,
    );
    assert!(Reply::parse(duplicate.as_bytes(), &request).is_err());
    assert!(Reply::parse(&vec![b' '; editor_codec::REPLY_BYTES + 1], &request).is_err());
}

#[test]
fn shared_hostile_vectors_and_depth_budget_reject_without_io() {
    let vectors = vectors();
    for case in vectors["invalidRequests"].as_array().unwrap() {
        assert!(
            Request::parse(case["utf8"].as_str().unwrap().as_bytes(), &context()).is_err(),
            "{}",
            case["name"]
        );
    }
    for case in vectors["invalidReplies"].as_array().unwrap() {
        let request = Request::parse(&bytes(&case["request"]), &context()).unwrap();
        assert!(
            Reply::parse(case["utf8"].as_str().unwrap().as_bytes(), &request).is_err(),
            "{}",
            case["name"]
        );
    }
    let raw = String::from_utf8(bytes(&write())).unwrap();
    let deep = raw.replace(
        "\"label\":\"Move 🦊\"",
        &format!("\"label\":{}0{}", "[".repeat(20), "]".repeat(20)),
    );
    assert!(Request::parse(deep.as_bytes(), &context()).is_err());
    let request = Request::parse(&bytes(&profile()), &context()).unwrap();
    let mut page = vectors["cases"][0]["reply"].clone();
    let ninth = page["controls"][0].clone();
    page["controls"].as_array_mut().unwrap().push(ninth);
    assert!(Reply::parse(&bytes(&page), &request).is_err());
}
