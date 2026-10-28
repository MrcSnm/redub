PARENT_PID=$1
NEW_REDUB=$2
OLD_REDUB=$3

while ps -p "$PARENT_PID" > /dev/null; do
  sleep 1
done

# Rename first so the replacement also works where overwriting a running binary is not allowed.
BACKUP="$OLD_REDUB.old.$$"
[ -e "$OLD_REDUB" ] && mv -f "$OLD_REDUB" "$BACKUP"
if cp "$NEW_REDUB" "$OLD_REDUB.tmp" && chmod +x "$OLD_REDUB.tmp" && mv -f "$OLD_REDUB.tmp" "$OLD_REDUB"; then
  rm -f "$BACKUP"
  rm -f "$OLD_REDUB".old.*
else
  [ -e "$BACKUP" ] && mv -f "$BACKUP" "$OLD_REDUB"
  exit 1
fi
