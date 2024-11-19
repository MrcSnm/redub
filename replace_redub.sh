PARENT_PID=$0
NEW_REDUB=$1
OLD_REDUB=$2

while ps -p $parent_pid > /dev/null; do
  sleep 1
done
cp -f $NEW_REDUB $OLD_REDUB
chmod +x $OLD_REDUB #Old is now the now one