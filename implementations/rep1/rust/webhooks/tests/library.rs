//! Tests of the public library API.

use webhooks::{
    base64, hex, hmac_sha256, sha256, sign_header, simulate, verify, DeliveryStatus, Endpoint, Event,
    Filter, Response, Secret, VerifyFailure, VerifyOutcome,
};

#[test]
fn primitives_agree_with_published_vectors() {
    assert_eq!(
        hex::encode(&sha256(b"abc")),
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    );
    assert_eq!(
        hex::encode(&hmac_sha256(&[0x0b; 20], b"Hi There")),
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
    );
    assert_eq!(base64::encode(b"foo"), "Zm9v");
}

#[test]
fn sign_then_verify_with_rotation() {
    let old = Secret::parse("whsec_c2VjcmV0").unwrap();
    let new = Secret::parse("whsec_b3RoZXI").unwrap();
    let body = b"payload";
    // Sender signs with both; a receiver that only knows the new key still verifies.
    let header = sign_header(&[old.clone(), new.clone()], "msg_1", "1700000000", body);
    assert_eq!(
        verify(&[new], "msg_1", "1700000000", 1700000000, header.as_bytes(), body),
        VerifyOutcome::Ok { secret: 0, token: 1 }
    );
    assert_eq!(
        verify(&[old], "msg_1", "1700000000", 1700000000, header.as_bytes(), b"tampered"),
        VerifyOutcome::Fail(VerifyFailure::NoMatch)
    );
}

#[test]
fn simulation_with_disabled_endpoint() {
    let endpoints = vec![Endpoint {
        id: "gone".into(),
        secrets: vec![Secret::parse("c2VjcmV0").unwrap()],
        filter: Filter::All,
        script: vec![Response::Status(410)],
    }];
    let events: Vec<Event> = (0..3)
        .map(|i| Event { id: format!("e{i}"), ts: i, kind: "t".into(), payload: vec![] })
        .collect();
    let report = simulate(&endpoints, &events);
    assert_eq!(report.attempts.len(), 1);
    let statuses: Vec<_> = report.deliveries.iter().map(|d| d.status).collect();
    assert_eq!(statuses, [DeliveryStatus::Failed, DeliveryStatus::Disabled, DeliveryStatus::Disabled]);
}
