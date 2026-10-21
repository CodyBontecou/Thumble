# Thumble

Thumble connects an agent-configured local authority to a phone controller and a native input receiver.

## Language

**Pairing window**:
A temporary opportunity for one phone to prove possession of an explicitly issued pairing secret. An open window is not a trusted phone or an input session.

**Trusted phone**:
A phone identity whose enrollment has been committed by the local authority and can be revoked by its owner.

**Input session**:
A bounded authorization for one trusted phone to send physical controller state for one activation generation.

**Activation generation**:
The identity of a particular activated runtime configuration. Replacing it retires input associated with the previous activation.

**Persistent host identity**:
The native host's private TLS key, certificate and public certificate pin, retained across receiver restarts. It does not identify a temporary authority process or authorize a phone/input session.

**Phone credential**:
A secret establishing one phone's trust relationship with one host. It is distinct from the temporary pairing secret and an input session key.

**Credential epoch**:
The monotonically increasing version of a phone's enrolled credential. Re-enrollment invalidates the previous credential; it does not reuse an activation generation or input sequence.

**Enrollment acknowledgment**:
The phone's confirmation that it retained its newly issued credential. It completes enrollment delivery without granting an input session.
