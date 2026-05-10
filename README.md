# KDE Linux Packages

This is the repository containing the pipeline to build KDE packages for [KDE Linux](https://community.kde.org/%F0%9F%8D%8C).

## Local Development

To build the packages locally, you need to have docker installed. Then, you can run the following command:

```bash
./run-local.sh
```

It caches partial builds in the `/builder` directory.

Once the build is done, you can find the rootfs in the `tree` directory.
