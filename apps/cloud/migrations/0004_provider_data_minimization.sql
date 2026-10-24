-- Provider ID tokens are verified during login but unused after it. Some carry
-- avatar URLs. Access/refresh credentials stay encrypted for revocation.
UPDATE "account" SET idToken = NULL WHERE idToken IS NOT NULL;
