# Certbot [![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE) [![Lifecycle:Stable](https://img.shields.io/badge/Lifecycle-Stable-97ca00)](https://github.com/bcgov/repomountie/blob/master/doc/lifecycle-badges.md)

Automatically update TLS Certificates on OpenShift Routes

_Update (August 2023) - Entrust Certificate Services has discontinued ACMEv1 protocol. Current users of BCDevOps Certbot will be unable to renew their certificates at this time if they are using OCIO Identity Management Services' Entrust Certificate Services._

_Update (November 2023) - At this time, the underlying EFF Certbot project and Entrust Certificate Services both support the newer ACMEv2 protocol. However, BCDevOps Certbot currently only supports the older, deprecated, ACMEv1 protocol, and OCIO IMS has not enabled ACMEv2 protocol support at this time. Please consider contacting OCIO Identity Management Services to express your need for ACMEv2 and Certbot support._

To learn more about the **Common Services** available visit the [Common Services Showcase](https://bcgov.github.io/common-service-showcase/) page.

## Table of Contents

- [Certbot  ](#certbot--)
  - [Table of Contents](#table-of-contents)
  - [Summary](#summary)
  - [Environment Variables](#environment-variables)
  - [Quick Start](#quick-start)
    - [Manual Run](#manual-run)
    - [Cleanup](#cleanup)
  - [Entrust Usage](#entrust-usage)
  - [Tips](#tips)
  - [Appendix](#appendix)
    - [References](#references)
    - [Errata](#errata)
  - [License](#license)

## Summary

- Can utilize <https://letsencrypt.org/> or other ACME compliant Certificate Authority for issuing certificates
- Leverages and extends <https://certbot.eff.org/> for managing (create/renew) certificates
- Should only be executed on Openshift Container Platform
- Creates an OpenShift `CronJob` which will run on a regular schedule for renewing TLS certificates
  - The `CronJob` will manage all `Route` objects annotated with the label `certbot-managed=true`
  - You have the option of a single certificate being issued/renewed for all the managed hosts/domains, or of an individual certificate being issued/renewed for each managed host/domain.
- If a cert is created/renewed, patch the new certificate to the managed OpenShift routes

## Environment Variables

The Certbot container image supports an array of environment variables to configure how it will behave. Certbot behavior can be modified by modifying which variables are defined. The following variables change the way how the internal Certbot application will behave.

| Environment Variable | Default Value | Notes |
| --- | --- | --- |
| `CERTBOT_CONFIG_DIR` | `/etc/letsencrypt` | Certbot Config Directory (Should be backed by a persistent volume) |
| `CERTBOT_DEPLOY_DIR` | `/etc/letsencrypt/renewal-hooks/deploy` | Certbot Deploy Directory |
| `CERTBOT_LOGS_DIR` | `/var/log/letsencrypt` | Certbot Log Directory |
| `CERTBOT_WORK_DIR` | `/var/lib/letsencrypt` | Certbot Working Directory |
| `CERTBOT_DEBUG` | `false` | Enable Certbot debug logging |
| `CERTBOT_DELETE_ACME_ROUTES` | `true` | Automatically clean up temporary ACME challenge routes on completion |
| `CERTBOT_DRY_RUN` | `false` | Performs a mock Certbot execution for CSR signability |
| `CERTBOT_EMAIL` | | Correspondence email to register with Certificate Authority |
| `CERTBOT_RSA_KEY_SIZE` | `2048` | Key length for RSA keypair generation |
| `CERTBOT_STAGING` | `false` | Use self-signed cert renewals. Must be `false` if using [Entrust](#entrust-usage)) |
| `CERTBOT_SUBSET` | `true` | Allow Certbot to pass ACME challenge if at least one domain succeeds |
| `CERTBOT_CERT_PER_HOST` | `false` | Manage an individual certificate per unique managed host (domain name), if true, otherwise, manage a single certificate for all managed hosts (domain names) |

## Quick Start

The following provides you a quick way to get Certbot set up and running as an OpenShift cronjob.

1. Point to the appropriate project/namespace on OpenShift

    ```sh
    export NAMESPACE=<YOURNAMESPACE>

    oc project $NAMESPACE
    ```

1. Ensure that the Routes you want Certbot to manage have been annotated with the label `certbot-managed=true`. You can list routes that meet this criteria with the following:

    ```sh
    oc get route -n $NAMESPACE -l certbot-managed=true -o=jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
    ```

1. Install Certbot to your project/namespace by processing `certbot.dc.yaml` to create the CronJob and supporting objects (ServiceAccount, RoleBinding, PVC, etc).

    This template accepts the following parameters which loosely corresponds with the [Environment Variables](#environment-variables) mentioned above (add with -p to the `oc process` command):

    | Parameter | Default Value | Description |
    | --- | --- | --- |
    | `CERTBOT_DEBUG` | `false` | Run Certbot in debug mode |
    | `CERTBOT_DELETE_ACME_ROUTES` | `true` | Self cleanup temporary ACME routes when done |
    | `CERTBOT_DRYRUN` | `false` | Run without executing |
    | `CERTBOT_EMAIL` | | Email where CSR requests are sent to. For [Entrust](#entrust-usage), Product Owner's `*@gov.bc.ca` is suggested |
    | `CERTBOT_SERVER` | `https://acme-v02.api.letsencrypt.org/directory` | ACME Certbot endpoint. For BC Gov SSL, see [Entrust](#entrust-usage). |
    | `CERTBOT_STAGING` | `false` | Use self-signed cert renewals. Must be `false` if using [Entrust](#entrust-usage)) |
    | `CERTBOT_SUBSET` | `true` | Allow domain validation to pass if a subset of them are valid |
    | `CERTBOT_CERT_PER_HOST` | `false` | Manage an individual certificate per unique managed host (domain name), if true, otherwise, manage a single certificate for all managed hosts (domain names) |
    | `CRON_SCHEDULE` | `0 0 * * 1,4` | [Cronjob](https://crontab.guru) Schedule |
    | `CRON_SUSPEND` | `false` | Suspend cronjob |
    | `IMAGE_REGISTRY` | `ghcr.io` | Image Registry |
    | `IMAGE_NAMESPACE` | `bcgov` | Image Namespace |
    | `IMAGE_NAME` | `certbot` | Image Name |
    | `IMAGE_TAG` | `latest` | Image Tag. We recommend pinning this to a specific release veresion for stability |

    - For non-prod environments, you may set `CERTBOT_STAGING=true`, so you don't hit any service limits with LetsEncrypt.
    - By default, this template will use LetsEncrypt for certificate generation. If you are just testing, you may use Let's Encrypt testing endpoint `https://acme-staging-v02.api.letsencrypt.org/directory` to avoid being rate limited.
    - For your production applications, we strongly recommend **NOT** using LetsEncrypt certificates. Contact your ministry/department to determine best practices for production SSL/TLS certificate management.
    - If you are using a certificate provider that gives you extra domains on top of what you have requested (like Entrust), you should make sure that the `CERTBOT_SUBSET` option is set to true. Otherwise certificate renewals will always fail because their extra domain will never be managed on our end and choke. If you require stringent domain validation, set `CERTBOT_SUBSET` to false explicitly.

    ```sh
    export CERTBOT_EMAIL=<some-valid@email.com>
    export CERTBOT_SERVER=<YOURCERTBOTSERVER>

    oc process -n $NAMESPACE -f "https://raw.githubusercontent.com/BCDevOps/certbot/master/openshift/certbot.dc.yaml" -p CERTBOT_EMAIL=$CERTBOT_EMAIL -p CERTBOT_SERVER=$CERTBOT_SERVER | oc apply -n $NAMESPACE -f -
    ```

    _PS: You MUST supply a valid email address!_

### Manual Run

If you need to run the CronJob manually, you can do that by running:

```sh
# Create a Job
oc create job -n $NAMESPACE "certbot-manual-$(date +%s)" --from=cronjob/certbot

# Delete any previous manual Jobs created
# Note: When there are no jobs to delete, you will get an error for oc delete.
oc get job -n $NAMESPACE -o name | grep -F -e '-manual-' | xargs oc delete -n $NAMESPACE
```

### Cleanup

To remove certbot from your namespace, run the following commands. All build related manifests will have a `build=certbot` label, and all cronjob application related manifests will have an `app=certbot` label.

```sh
export NAMESPACE=<YOURNAMESPACE>

# Delete all manifests generated by certbot.bc.yaml
oc delete all -n $NAMESPACE -l build=certbot

# Delete all manifests generated by certbot.dc.yaml
oc delete cronjob,pvc,rolebinding,sa -n $NAMESPACE -l app=certbot
```

## Entrust Usage

**Update: As of August 2023, BC Gov's security certificate supplier, Entrust, has discontinued support for Certbot. Currently, Certbot cannot be used to manage your Entrust certificates.**

Entrust is the only approved certificate provider for BC Gov production environments currently.

Where Entrust does support Certbot, there are a few extra steps required to request certificates from Entrust instead of LetsEncrypt.

1. Start by creating the deployment config found in the [Quick Start](#quick-start) section

1. Modify the `CERTBOT_SERVER` parameter in the deployment config to use Entrust

    | Parameter | Default Value | Description |
    | --- | --- | --- |
    | `CERTBOT_SERVER` | `https://www.entrust.net/acme/api/v1/directory/xx-xxxx-xxxx` | Where `xx-xxxx-xxxx` is the directory ID.  This value may vary between different ministry organizations.  Please contact your organization to determine this value. |

1. Make sure `CERTBOT_STAGING` is set to `false`.  The Entrust server does not have a staging mode

1. If a Certbot job has previously on the same route using LetsEncrypt server, then you will need to delete the existing PVC.  This will remove old Let's Encrypt files and a new PVC will be created on the next step.

1. Apply the deployment config and run the job manually or by cron trigger. The job logs will display it has failed to obtain the certificates and the route will remain unmodified.  This is normal because the certificate request still needs to be approved by your ministry first.

1. In the `CERTBOT_EMAIL` inbox you should receive an email from `auto-notice@entrust.com` containing a `Tracking ID`.

1. At this point you need to contact the appropriate group in your ministry to create an iStore order to approve the certificate request.  For NRM teams, please have your product owner create a [Service Desk](https://apps.nrs.gov.bc.ca/int/jira/servicedesk/customer/portal/1) request containing the following information.
   - Domain for the certificate
   - Entrust Tracking ID
   - iStore Coding
   - Expense Authority

1. Once the iStore order has been created and approved, you should receive another email from `auto-notice@entrust.com` letting you know the request has been approved.

1. Re-run the job and Certbot should obtain the certificates and install them automatically.

## Tips

1. If you are going to setup automatic cert renewals for the first time, backup "Certficate", "Private Key" and "CA Certificate" contents from your route.

1. List your cron jobs

    ```sh
    export NAMESPACE=<YOURNAMESPACE>

    oc get -n $NAMESPACE cronjob
    ```

1. To describe your cron job

    ```sh
    export NAMESPACE=<YOURNAMESPACE>

    oc describe -n $NAMESPACE cronjob/certbot
    ```

1. To see your cron jobs in Openshift Console: Administrator View -> Workloads > Jobs

1. To access the logs for cron jobs in Openshift Console, check for the latest completed/failed cronjob pods in you pod list (Administrator View -> Workloads > Pods).

1. If you are seeing errors in the logs and need to troubleshoot, you may use optional parameters `CERTBOT_DEBUG` and `CERTBOT_DELETE_ACME_ROUTES`.

    ```sh
    export NAMESPACE=<YOURNAMESPACE>
    export CERTBOT_SERVER=<YOURCERTBOTSERVER>
    export CERTBOT_EMAIL=<some-valid@email.com>

    oc process -n $NAMESPACE -f "https://raw.githubusercontent.com/BCDevOps/certbot/master/openshift/certbot.dc.yaml" -p CERTBOT_EMAIL=$EMAIL -p CERTBOT_SERVER=$CERTBOT_SERVER -p CERTBOT_STAGING=false -p CERTBOT_DEBUG=true -p CERTBOT_DELETE_ACME_ROUTES=false | oc apply -n $NAMESPACE -f -
    ```

    _PS: Ensure that you manually delete the ACME Route and Service after you are done troubleshooting and redeploy without the DEBUG and DELETE_ACME_ROUTES options!_

1. If you end up running the setup process multiple times, ensure that you have deleted all the duplicate copies of those cron jobs and only keep the latest one. Or to delete all the certbot jobs and start fresh you can use the below.

    ```sh
    export NAMESPACE=<YOURNAMESPACE>

    oc get job -n $NAMESPACE -o name | grep -F -e 'certbot' | xargs oc delete
    oc get cronjob -n $NAMESPACE -o name | grep -F -e 'certbot' | xargs oc delete
    ```

1. To suspend a cronjob in your namespace, you can use the below patch command.

    ```sh
    export NAMESPACE=<YOURNAMESPACE>

    oc patch cronjob -n $NAMESPACE certbot -p '{"spec" : {"suspend" : false }}'
    ```

1. To resume a cronjob in your namespace, you can use the below patch command.

    ```sh
    export NAMESPACE=<YOURNAMESPACE>

    oc patch cronjob -n $NAMESPACE certbot -p '{"spec" : {"suspend" : true }}'
    ```

## Appendix

### References

- <https://certbot.eff.org/>
- <https://certbot.eff.org/docs/using.html#webroot>
- <https://certbot.eff.org/docs/using.html#renewing-certificates>
- <https://letsencrypt.org/>
- <https://letsencrypt.org/how-it-works/>
- <https://github.com/certbot/certbot/issues/2697#issuecomment-242360098>
- <https://www.entrust.net/knowledge-base/technote.cfm?tn=70882>

### Errata

If you need to build Certbot directly on the cluster, you can do so by processing `certbot.bc.yaml` to create the required build objects. For most situations, this is no longer needed.

This template accepts the following parameters (add with -p to the `oc process` command):

| Parameter | Default Value | Description |
| --- | --- | --- |
| `GIT_REF` | `master` | Git Pull Request or Branch Reference (i.e. 'pull/CHANGE_ID/head') |
| `GIT_URL` | `https://github.com/BCDevOps/certbot.git` | Git Repository URL |

```sh
oc process -n $NAMESPACE -f "https://raw.githubusercontent.com/BCDevOps/certbot/master/openshift/certbot.bc.yaml" | oc apply -n $NAMESPACE -f -
```

## License

```text
Copyright 2018 Province of British Columbia

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
