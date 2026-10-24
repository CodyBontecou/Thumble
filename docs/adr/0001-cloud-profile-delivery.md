# Cloud profile delivery and receiver activation have separate authority

Status: accepted for the cloud pilot.

The current receiver owns LAN activation revisions and input leases. Giving cloud sync independent authority to replace the connected controller would risk a visible layout with a different receiver mapping.

Cloud stores immutable profile revisions and device-targeted deliveries. Phones can render those profiles in offline practice and acknowledge render commits. While paired to a Mac, they defer cloud rendering. No cloud delivery acknowledges Mac input readiness. This permits useful agent-to-phone design before Mac setup and preserves the existing receiver protocol. A later milestone will coordinate cloud-published profiles through the receiver activation path rather than reuse unrelated revision counters.

Identity uses an established OAuth/OIDC provider. Provider deployment configuration is a prerequisite for live account sign-in; unconfigured builds fail closed. The pilot does not add a password service or publish marketplace listings.
