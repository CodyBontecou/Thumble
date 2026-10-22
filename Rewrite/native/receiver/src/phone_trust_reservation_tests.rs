// Included in phone_trust::tests: exercises the real SQLite transaction boundary.
fn legacy_fixture(root: &Root, reject_migration: bool) -> [u8; 32] {
    let path = root.0.join("phone-trust.sqlite3");
    crate::security::file(&path, false).unwrap();
    let connection = Connection::open(path).unwrap();
    let legacy = SCHEMA.replace(
        ",reserved_until INTEGER NOT NULL CHECK(reserved_until>=0)",
        "",
    );
    connection.execute_batch(&legacy).unwrap();
    connection
        .pragma_update(None, "application_id", APP_ID)
        .unwrap();
    connection.pragma_update(None, "user_version", 1).unwrap();
    let pin = host_identity::load_existing(&root.0).unwrap().pin().hex();
    connection
        .execute("INSERT INTO trust_meta VALUES(1,?1,100)", [&pin])
        .unwrap();
    let token = [42; 32];
    connection
        .execute(
            "INSERT INTO phones VALUES('legacy','Preserved',7,1,?1,10000,100)",
            [verifier(&pin, "legacy", &token).as_slice()],
        )
        .unwrap();
    if reject_migration {
        connection.execute_batch("CREATE TRIGGER reject_migration BEFORE UPDATE ON trust_meta BEGIN SELECT RAISE(ABORT,'migration fixture'); END;").unwrap();
    }
    token
}
#[test]
fn legacy_migration_preserves_credentials_epochs_and_clock_transactionally() {
    for rejected in [false, true] {
        let root = Root::new();
        let token = legacy_fixture(&root, rejected);
        if rejected {
            assert_eq!(
                PhoneTrustStore::open(&root.0).err(),
                Some("phone_trust_storage_invalid")
            );
            let connection = Connection::open(root.0.join("phone-trust.sqlite3")).unwrap();
            assert_eq!(
                connection
                    .pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
                    .unwrap(),
                1
            );
            assert!(
                connection
                    .prepare("SELECT reserved_until FROM trust_meta")
                    .is_err(),
                "ALTER must roll back too"
            );
            assert_eq!(
                connection
                    .query_row(
                        "SELECT epoch FROM phones WHERE phone_id='legacy'",
                        [],
                        |r| r.get::<_, i64>(0)
                    )
                    .unwrap(),
                7
            );
            connection
                .execute_batch("DROP TRIGGER reject_migration")
                .unwrap();
        }
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        assert_eq!(
            store
                .connection
                .pragma_query_value(None, "user_version", |r| r.get::<_, i64>(0))
                .unwrap(),
            2
        );
        assert_eq!(store.clock.ceiling(), 100);
        assert_eq!(
            store.authenticate("legacy", &token, 99).err(),
            Some("phone_trust_clock_rollback")
        );
        let phone = store.authenticate("legacy", &token, 100).unwrap();
        assert_eq!(phone.credential_epoch, "7");
        assert_eq!(phone.label, "Preserved");
        assert_eq!(store.clock.ceiling(), 1100);
        drop(store);
        let mut reopened = PhoneTrustStore::open(&root.0).unwrap();
        assert_eq!(
            reopened.authenticate("legacy", &token, 1099).err(),
            Some("phone_trust_clock_rollback")
        );
        assert!(reopened.authenticate("legacy", &token, 1100).is_ok());
    }
}
#[test]
fn failed_reservation_commit_stops_cached_authorization_but_revocation_remains_durable() {
    let root = Root::new();
    let mut store = PhoneTrustStore::open(&root.0).unwrap();
    let issued = store.enroll_after_pairing("phone-a", "A", 100).unwrap();
    let authorization = store.cached_authorization(issued.phone()).unwrap();
    assert_eq!(authorization.clock.sample(&mut || Ok(101)), Ok(101));
    store.connection.execute_batch("CREATE TRIGGER reject_reservation BEFORE UPDATE ON trust_meta BEGIN SELECT RAISE(ABORT,'reservation fixture'); END;").unwrap();
    assert_eq!(
        store.reserve_clock(&mut || Ok(102)),
        Err("phone_trust_storage_invalid")
    );
    assert_eq!(
        authorization.clock.sample(&mut || Ok(103)),
        Err("phone_trust_reservation_failed")
    );
    assert_eq!(store.clock.ceiling(), 1100);
    assert_eq!(
        store.authenticate("phone-a", &issued.token, 103).err(),
        Some("phone_trust_reservation_failed")
    );
    assert_eq!(
        store
            .enroll_after_pairing("phone-a", "Replacement", 103)
            .err(),
        Some("phone_trust_reservation_failed")
    );

    store
        .connection
        .execute_batch("DROP TRIGGER reject_reservation")
        .unwrap();
    store.revoke("phone-a", 1).unwrap();
    assert!(authorization.guard().is_err());
    assert_eq!(
        authorization.clock.sample(&mut || Ok(104)),
        Err("phone_trust_reservation_failed")
    );
    drop(store);
    let mut reopened = PhoneTrustStore::open(&root.0).unwrap();
    assert!(!reopened.list().unwrap()[0].active);
    assert!(reopened
        .authenticate("phone-a", &issued.token, 1101)
        .is_err());
}
#[test]
fn revoke_and_reenroll_wait_for_inflight_forward_and_permanently_fence_the_old_epoch() {
    use std::{
        sync::{mpsc, Arc, Mutex},
        time::Duration,
    };
    for replace in [false, true] {
        let root = Root::new();
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        let issued = store.enroll_after_pairing("phone-a", "A", 100).unwrap();
        let authorization = store.cached_authorization(issued.phone()).unwrap();
        let guard = authorization.guard().unwrap();
        let store = Arc::new(Mutex::new(store));
        let (finished, completion) = mpsc::channel();
        thread::scope(|scope| {
            let store = store.clone();
            scope.spawn(move || {
                let mut store = store.lock().unwrap();
                let result = if replace {
                    store
                        .enroll_after_pairing("phone-a", "New", 102)
                        .map(|_| ())
                } else {
                    store.revoke("phone-a", 102)
                };
                finished.send(result).unwrap();
            });
            assert!(matches!(
                completion.recv_timeout(Duration::from_millis(25)),
                Err(mpsc::RecvTimeoutError::Timeout)
            ));
            drop(guard);
            completion
                .recv_timeout(Duration::from_secs(1))
                .unwrap()
                .unwrap();
        });
        assert!(authorization.guard().is_err());
        let mut store = store.lock().unwrap();
        store.reserve_clock(&mut || Ok(103)).unwrap();
        assert!(
            authorization.guard().is_err(),
            "renewing clock must not revive old epoch"
        );
        assert!(store.authenticate("phone-a", &issued.token, 104).is_err());
        if replace {
            let current = store.authorize_epoch("phone-a", "2", 104).unwrap();
            let fresh = store.cached_authorization(&current).unwrap();
            assert!(fresh.guard().is_ok());
        }
    }
}
#[test]
fn startup_waits_only_normal_reservation_remainder_and_keeps_revoke_available_after_wall_rollback()
{
    use std::time::Instant;
    for rollback in [false, true] {
        let root = Root::new();
        let mut store = PhoneTrustStore::open(&root.0).unwrap();
        let real_now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_millis() as u64;
        let issued = store
            .enroll_after_pairing("phone-a", "A", real_now)
            .unwrap();
        let floor = real_now + if rollback { 5_000 } else { 100 };
        store
            .connection
            .execute(
                "UPDATE trust_meta SET last_time=?1,reserved_until=?2",
                params![
                    i64::try_from(floor - 100).unwrap(),
                    i64::try_from(floor).unwrap()
                ],
            )
            .unwrap();
        drop(store);
        let started = Instant::now();
        let mut reopened = PhoneTrustStore::open(&root.0).unwrap();
        assert!(started.elapsed() < Duration::from_secs(1));
        if rollback {
            assert_eq!(
                reopened
                    .authenticate("phone-a", &issued.token, real_now)
                    .err(),
                Some("phone_trust_clock_rollback")
            );
            reopened.revoke("phone-a", real_now).unwrap();
            assert!(!reopened.list().unwrap()[0].active);
        } else {
            let after = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis() as u64;
            assert!(
                after >= floor,
                "normal restart must wait out the committed ceiling"
            );
            assert!(reopened
                .authenticate("phone-a", &issued.token, after)
                .is_ok());
        }
    }
}
