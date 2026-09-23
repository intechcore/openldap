# Security policy

## Reporting a vulnerability

Report a vulnerability privately through GitHub: open the **Security** tab of this repository
and choose **Report a vulnerability**. Do not open a public issue for it.

We answer within a week. The fix goes into the next image release, and the GitHub release notes
name it.

## Supported versions

Only the latest image, `ghcr.io/intechcore/openldap:latest`, gets fixes. The weekly rebuild picks up fixed Debian packages
and base image updates on its own, see the README.

## Scope

The image: the Dockerfile, `entrypoint.sh`, `reload-tls.sh`, the schemas, and the release workflows.

Vulnerabilities in the upstream software (OpenLDAP, the Symas packages, Debian packages) belong to the upstream project. Tell us as
well if the image is affected, so we can release a fixed image when the upstream fix is out.
