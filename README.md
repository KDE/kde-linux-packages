# KDE Linux Packages

This is the repository containing the pipeline to build KDE packages for [KDE Linux](https://community.kde.org/%F0%9F%8D%8C).

## Local Development

To build the packages locally, you need to have docker installed. Then, you can run the following command:

```bash
./build_kde_docker.sh
```

It caches partial builds in the `pkgbuilds` directory, so you can just run it again if it gets interrupted.

Once the build is done, you can find the packages in the `artifacts` directory.

Note: The contents of the `artifacts/banana` and `artifacts/banana-debug` directories are valid pacman repositories.
You can add them to your pacman configuration to install the packages locally for testing.


## Configuration

When running the pipeline manually from GitLab, the **`REPO_METADATA_BRANCH`** variable
can be set to use a custom branch of `sysadmin/repo-metadata`. This is useful for testing
changes to KDE project metadata (e.g. build configs or dependency info) before they land
on `master`.

## Investigation

The build is done in two steps:
1. Create a docker image with all the dependencies and build environment.
2. Run the build inside the docker image.

If you want to reproduce issues that happen in the build step, you can enter the container with:

```bash
./build_kde_docker.sh bash
```

Then you can run the build command manually:

```bash
./make-packages.sh
```