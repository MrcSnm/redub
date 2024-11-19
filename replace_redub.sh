PARENT_PID=$1
NEW_REDUB=$2
OLD_REDUB=$3

while ps -p $PARENT_PID > /dev/null; do
  sleep 1
done
cp -f $NEW_REDUB $OLD_REDUB
chmod +x $OLD_REDUB #Old is now the now one