# TechNexion Intel IPU7 Camera Deployment for Panther Lake

This repository builds and packages the Intel IPU7 camera stack and the
TechNexion Linux kernel for Panther Lake platforms.

The build process produces a self-contained deployment bundle containing:

- TechNexion Linux kernel Debian package
- Intel IPU7 camera userspace Debian package
- Target installation script

## Branches

| Branch | Camera configuration | Kernel overlay branch |
|---|---|---|
| `main` | Standard TechNexion Panther Lake build | `main` |
| `lexcom` | Lexcom-specific build | `lexcom` |
| `biostar` | BIOSTAR BIPTL-IHT, TEVS AR0821 on CSI port 0 | `biostar` |

Kernel configurations and patches are provided by:

[TechNexion-Vision/tn-intel-linux-kernel-overlay](https://github.com/TechNexion-Vision/tn-intel-linux-kernel-overlay)

The kernel overlay branch is pinned in `ptl-camera.sh`. The `biostar`
branch clones the overlay's `biostar` branch into
`ptl-camera-out/tn-intel-linux-kernel-overlay`.

## Build Requirements

Use an Ubuntu x86-64 build host with:

- Git
- Docker
- Debian packaging tools
- Linux kernel build dependencies
- Sufficient disk space for a complete kernel build

The complete build can take a significant amount of time and disk space.

## Standard Build

```bash
git clone https://github.com/TechNexion-Vision/tn-intel-camera-deploy.git
cd tn-intel-camera-deploy
git switch main

./ptl-camera.sh --all
```

This builds the standard Panther Lake package using the `main` branch of
`tn-intel-linux-kernel-overlay`.

## Lexcom Build

Use a separate working directory to avoid mixing build outputs:

```bash
git clone --branch lexcom \
  https://github.com/TechNexion-Vision/tn-intel-camera-deploy.git \
  tn-intel-camera-deploy-lexcom

cd tn-intel-camera-deploy-lexcom
./ptl-camera.sh --all
```

This builds the Lexcom package using the `lexcom` branch of
`tn-intel-linux-kernel-overlay`.

## Build Process

With `--all`, `ptl-camera.sh` performs the following operations:

1. Clones the Intel IPU7 camera components and the matching kernel overlay.
2. Builds the camera userspace components in Docker.
3. Builds the TechNexion Linux kernel Debian package.
4. Creates the IPU7 camera userspace Debian package.
5. Creates the final deployment bundle.

Running `./ptl-camera.sh` without `--all` only rebuilds the camera package and
deployment bundle from an existing build tree.

## Output

After a successful build:

```text
ptl-camera-out/ipu7-camera-ptl.deb
ptl-camera-out/tn-camera-ptl.tar.gz
```

`tn-camera-ptl.tar.gz` is the final deployment bundle. It contains:

```text
tn-camera-ptl/
├── install.sh
├── ipu7-camera-ptl.deb
└── linux-image-*.deb
```

## Install on the Target

Copy the deployment bundle to the target:

```bash
scp ptl-camera-out/tn-camera-ptl.tar.gz <user>@<TARGET_IP>:~/
```

Log in to the target and install it:

```bash
ssh <user>@<TARGET_IP>
tar xf tn-camera-ptl.tar.gz
sudo ./tn-camera-ptl/install.sh
sudo reboot
```

After rebooting, the target loads the newly installed kernel and IPU7 camera
stack.

## Notes

- Do not reuse the same build directory between `main` and `lexcom`.
- Camera firmware is not included; the target operating system provides the
  required firmware.
- Upstream Intel camera components remain subject to their respective licenses.

## BIOSTAR BIPTL-IHT

Use the `biostar` branch for BIPTL-IHT with TEVS AR0821 on CAM_CONN1.
The camera uses CSI port 0, I2C bus 1, and address 0x48. In BIOS, set
Camera1's GPIO Pin 1 Function to **Reset** (GPP_C8 / CAM_CONN1 pin 17).
The BIOS must provide working IPU7 CSE firmware.

Build with `./ptl-camera.sh --all`, or run `./ptl-camera.sh` to repackage
an existing build. Both paths include this branch's camera configuration.
After installation and reboot, the camera name for the launch script is
`tevs-ar0821`:

```bash
launch_video_pipeline_ptl.sh tevs-ar0821 1280x720 UYVY
```

On the tested board, the sensor probed successfully and a headless
1280x720 UYVY pipeline captured 30 frames.
