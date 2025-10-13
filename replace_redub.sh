PARENT_PID=$1
NEW_REDUB=$2
OLD_REDUB=$3

while ps -p $PARENT_PID > /dev/null; do
  sleep 1
done
cp $NEW_REDUB $OLD_REDUB.tmp
chmod +x $OLD_REDUB.tmp #Old is now the now one
mv -f $OLD_REDUB.tmp $OLD_REDUB