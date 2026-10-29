/* Versioned production profile; the disposable Linux probe reads these same
 * properties through the standalone collector's --profile command. Dynamic
 * paths, identity and deadline are supplied only by the trusted supervisor. */
#define SHIKIGAMI_WORKSPACE_SYSTEMD_PROFILE \
  "[\"Type=exec\",\"Restart=no\",\"RemainAfterExit=yes\"," \
  "\"TimeoutStopSec=1\",\"KillMode=control-group\",\"SendSIGKILL=yes\",\"Slice=system.slice\"," \
  "\"ProtectSystem=strict\",\"ReadWritePaths=/workspace /scratch\"," \
  "\"PrivateNetwork=yes\",\"PrivatePIDs=yes\",\"PrivateDevices=yes\"," \
  "\"NoNewPrivileges=yes\",\"CapabilityBoundingSet=\",\"ProtectControlGroups=yes\"," \
  "\"ProtectKernelTunables=yes\",\"ProtectKernelModules=yes\",\"RestrictNamespaces=yes\"," \
  "\"RestrictAddressFamilies=AF_UNIX\"," \
  "\"SystemCallFilter=~@mount @privileged @reboot @swap @module @raw-io @debug\"," \
  "\"SystemCallErrorNumber=EPERM\",\"ProtectProc=invisible\",\"ProcSubset=pid\"," \
  "\"TasksMax=64\",\"MemoryMax=128M\",\"LimitCORE=0\",\"UMask=0077\",\"StandardInput=null\"]"
