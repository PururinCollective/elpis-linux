# Shown at login on the console or over SSH.
case $- in *i*) ;; *) return 0 2>/dev/null ;; esac
echo
/usr/sbin/elpis-storage status 2>/dev/null
echo
echo "  elpis-save            keep settings across reboots (the system runs from RAM)"
echo "  elpis-update          install a newer Elpis ISO; the medium stays the fallback"
echo "  elpis-copy-to-disk    write this system to another disk"
echo "  logread -f            the log"
echo
