module redub.libs.adv_diff.helpers.index_of;
int indexOf(in string[] arr, string element, int startIndex = 0) pure nothrow @nogc
{
    if(startIndex < 0)
        return -1;
    for(int i = startIndex; i < arr.length; i++)
        if(arr[i] == element)
            return i;
    return -1;
}