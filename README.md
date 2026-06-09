# VCF 9.1 Disconnected Software Depot Sync Tool

PowerShell 7 / WPF UI wrapper for the Broadcom VCF Download Tool supporting disconnected and controlled-connectivity VMware Cloud Foundation 9.1 software depot workflows.

> Current documented release: **Rev1.1 / UI v1.2.2 Three-Modes**

---

## Purpose

This tool provides an operator-friendly UI for staging VCF 9.1 software depot content on a Windows jump host and uploading required binaries into Fleet Software Depot. It was built to simplify disconnected depot operations where direct connected-depot access is unavailable, blocked, or temporarily unsuitable.

The tool does **not** replace the Broadcom VCF Download Tool. It wraps the Broadcom tool and adds workflow guidance, state tracking, chunked upload handling, debug visibility, and retry controls.

---

## Typical Use Case

Use this tool when a VCF 9.1 environment must temporarily or permanently operate with a disconnected software depot model.

Example scenarios:

- SSL proxy or SSL inspection prevents the VCF 9.1 software depot workflow from completing successfully.
- A customer site requires a controlled jump-host staging process.
- The production rollout cannot wait for a connected-depot networking/proxy issue to be resolved.
- Fleet Software Depot must be populated manually from a staged DepotStore.

---

## High-Level Workflow

1. Validate the local VCF Download Tool path.
2. Generate a Software Depot ID.
3. Register the Software Depot ID in the Broadcom portal.
4. Paste the activation code into the UI.
5. Select a download mode.
6. Download binaries into a local DepotStore.
7. Validate TCP/443 connectivity to VCF Operations and Fleet Software Depot.
8. Upload staged binaries into Fleet Software Depot.
9. Refresh/resync Fleet or installer catalog if required.
10. Retry VCF install or lifecycle workflow.

---

## Download Modes

The tool now supports three download modes. These modes are intended to prevent the situation where Fleet shows binaries as available, but an install or lifecycle workflow cannot find the exact version or artifact it expects.

### Mode A — Base Platform INSTALL Only

**UI label:**

```text
Mode A - Base platform INSTALL only, all 9.1 catalog versions
```

Mode A targets base VCF platform install artifacts only. It is intended for the minimum platform install footprint while still collecting all 9.1 catalog versions available for those base components.

Mode A includes base components such as:

- `VCENTER`
- `SDDC_MANAGER_VCF`
- `NSX_T_MANAGER`
- `VSP`
- `DEPOT_SERVICE`
- `VCF_LICENSE_SERVER`
- `VCF_FLEET_LCM`
- `VCF_SDDC_LCM`
- `VIDB`
- `TELEMETRY_ACCEPTOR`
- `VCFDT`

Use Mode A when the goal is to stage only the base platform install artifacts needed for core VCF installation.

---

### Mode B — Base Platform + Add-On INSTALL Artifacts

**UI label:**

```text
Mode B - Base + HCX/Networks/Logging/Ops add-on INSTALL only, all 9.1 catalog versions
```

Mode B includes Mode A plus install-only artifacts for common add-on and adjacent services. It is designed for production deployments that may require optional services or later enablement without having to revisit depot population.

Mode B includes Mode A plus add-on components such as:

- `HCX`
- `VRNI` / VCF Operations for Networks
- `VRLI` / VCF Operations for Logs
- `VROPS` / VCF Operations
- `VRA` / VCF Automation
- `VCF_OPS_CLOUD_PROXY`
- `VCFMS_METRICS_STORE`
- `VCF_OBSERVABILITY_DATA_PLATFORM`
- `VCF_SALT`
- `VCF_SALT_RAAS`
- `VCF_SERVICE_VCD_MIGRATION_BACKEND`

Use Mode B when the environment needs base VCF installation content plus install-compatible add-ons such as HCX, Operations for Networks, Logging, Operations, Automation, Salt, and migration-related artifacts.

---

### Mode C — Everything Available in Catalog

**UI label:**

```text
Mode C - Everything available in catalog, all detected bundle types/components
```

Mode C is the broadest mode. The tool parses the local `productVersionCatalog.json` and attempts to include every bundle ID discovered in the catalog, regardless of detected component or bundle type.

Mode C is intended for maximum compatibility and broad depot population.

Use Mode C when:

- install discovery is failing and the missing component/version is unclear,
- the safest option is to stage everything exposed by the VCF 9.1 catalog,
- the environment has enough storage and time to download/upload the broadest possible set,
- troubleshooting requires ruling out missing depot artifacts.

> Note: Mode C may download artifacts beyond install-only payloads. The upload workflow remains component-oriented and install-focused unless additional upload-type support is explicitly added and validated.

---

## Catalog-Based Expansion Behavior

The three modes use the local catalog file when available:

```text
<DepotStore>\PROD\metadata\productVersionCatalog\v1\productVersionCatalog.json
```

If this file exists, the script parses it to discover available bundle IDs. If the catalog does not exist yet, the script falls back to a curated VCF 9.1 known-good ID list.

Recommended first-run process:

1. Run the download once to seed metadata if the DepotStore is empty.
2. Re-run the selected mode with **Force re-download** checked.
3. The second run can parse `productVersionCatalog.json` and expand the selected mode.

The UI logs this condition when catalog metadata is not available:

```text
Catalog not present or no IDs matched selected mode. Using curated fallback IDs.
Run again with Force re-download after metadata exists to expand selected mode.
```

---

## Upload Workflow

The upload workflow remains chunked by component group to reduce risk and improve recovery:

1. vCenter alone
2. VCF Automation alone
3. VCF services runtime alone
4. VCF Operations for Networks alone
5. NSX alone
6. Remaining services and add-ons

This design makes large imports easier to monitor and retry. If one component fails, the operator can retry that component without restarting the entire depot population process.

---

## State Files

The tool writes state files into the DepotStore:

```text
.vcf-download-state.json
.vcf-upload-state.json
```

These files allow the UI to skip work that has already completed.

Use **Force re-download** or **Force re-upload** when intentionally repeating a task, switching modes, or repopulating Fleet after changing the DepotStore contents.

---

## SSL Proxy / Certificate Notes

If downloads fail with Java PKIX or `unable to find valid certification path` errors, the VCF Download Tool bundled Java runtime likely does not trust the SSL inspection or proxy certificate chain.

Common failing endpoint:

```text
https://eapi.broadcom.com/vcf/generateToken
```

Common options:

1. Bypass SSL inspection for Broadcom endpoints such as:
   - `eapi.broadcom.com`
   - `dl.broadcom.com`
   - `vcf.broadcom.com`
   - `vcf.broadcom.net`
2. Import the customer SSL proxy root/intermediate certificate into the VCF Download Tool bundled Java truststore:

```text
<VCF_Download_Tool>\jre\win32\lib\security\cacerts
```

---

## Recommended Mode Selection

- Use **Mode A** for core VCF base platform install content.
- Use **Mode B** for production staging where base platform plus common add-ons are expected.
- Use **Mode C** for broadest compatibility or when troubleshooting missing install/lifecycle artifacts.

For most production rollouts where optional services may be needed later, **Mode B** is the recommended balance.

For troubleshooting “available in depot but installer cannot find install binaries,” start with **Mode B**, then use **Mode C** if the missing artifact/version is still unclear.

---

## Operational Recommendation

After downloading and uploading new artifacts:

1. Confirm Fleet Depot shows the expected binaries as available.
2. Refresh or resync Fleet/LCM catalog if the UI provides that option.
3. Retry the install or lifecycle workflow.
4. If the installer still cannot find binaries, capture the exact missing component/version and compare it to the Fleet Depot package list.

---

## Disclaimer

This tool is an operational wrapper around Broadcom VCF Download Tool commands. Always validate the workflow in a non-production or controlled environment before production use.


