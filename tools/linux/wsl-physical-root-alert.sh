# dualboot-linux-as-wsl: warn interactive shells under WSL about an unclean shutdown or
# ext4 errors of the physical root (see wsl-physical-root-check). Installed in /etc/profile.d.
case $- in *i*) [ -x /usr/local/sbin/wsl-physical-root-check ] && /usr/local/sbin/wsl-physical-root-check --login || true ;; esac
