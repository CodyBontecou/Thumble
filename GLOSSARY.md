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
