module hashmap;

enum SlotState : ubyte
{
	empty = 0,
	alive = 1
}

struct SString
{
	size_t length;
	private immutable(char)* ptr;
	enum size_t mask = 0b11UL << 62;

	pragma(inline, true)
	string toString() const
	{
		string ret;
		(cast(size_t*)&ret)[0] = length & ~mask;
		(cast(size_t*)&ret)[1] = cast(size_t)ptr;
		
		return ret;
	}

	pragma(inline, true)
	SString opAssign(string other)
	{
		length = other.length | extra;
		ptr = cast(immutable(char)*)other.ptr;
		return this;
	}

	pragma(inline, true)  bool opEquals(string other) const { return other == toString; }
	pragma(inline, true) ubyte extra() const { return cast(ubyte)((length & mask) >> 62);}

	pragma(inline, true) void setExtra(ubyte ex)
	{
		assert(ex <= 0b11, "Extra too big.");
		length |= (cast(size_t)ex) << 62;
	}
	alias toString this;

}

private	enum GrowthFactor = 2;
float getGrowthFactor(uint length)
{
	// if(length <= 128)
	// 	return 16;
	// else if(length <= 2 << 16)
	// 	return 8;
	return GrowthFactor;
}

struct HashMap(K, V)
{
	private enum SeparateSlotState = !is(K == string);
	// private enum SeparateSlotState = true;

	static if(!SeparateSlotState)
		private SString* _keys;
	else
		private K* _keys;
	private V* _values;
	uint capacity, length;
	uint collisionsInLength;
	enum DefaultInitSize = 8;
	enum ResizeFactor = 0.75;
	enum UseCollisionRateThreshold = 64;
	enum CollisionFactor = 0.25;

	static if(SeparateSlotState)
	{
		private SlotState* states;
		SlotState getState(const(SlotState)* stateArr, size_t index) const
		{
			auto arrayIndex = index >> 3;
			SlotState s = stateArr[arrayIndex];
			ubyte bitIndex = index & 7;
			return cast(SlotState)((s >> bitIndex) & 0b1);
		}

		pragma(inline, true) SlotState getState(size_t index) const
		{
			return getState(states, index);
		}
		void setState(size_t index, SlotState state)
		{
			auto arrayIndex = index >> 3;
			ubyte bitIndex = index & 7;
			states[arrayIndex] &= ~(1 << bitIndex);
			states[arrayIndex]|= state << bitIndex;
		}
		private pragma(inline) size_t getRequiredStateCount() const
		{
			return (capacity >> 3) + 1;
		}
	}
	else
	{
		void setState(size_t index, SlotState state)
		{
			_keys[index].setExtra(state);

			assert(getState(index) == state, " Set state false ");
		}
		SlotState getState(const(SString)* keysArr, size_t index) const
		{
			return cast(SlotState)(keysArr[index].extra);
		}
		SlotState getState(size_t index) const
		{
			return getState(_keys, index);
		}
	}

	private void setCapacity(size_t capacity = DefaultInitSize)
	{
		import core.memory;
		this.capacity = cast(uint)capacity;
		_keys = cast(typeof(_keys))GC.malloc(K.sizeof*capacity);
		_values = cast(V*)GC.malloc(V.sizeof*capacity);
		

		static if(SeparateSlotState)
		{
			states = cast(SlotState*)GC.malloc(getRequiredStateCount, GC.BlkAttr.NO_SCAN);
			states[0..getRequiredStateCount] = SlotState.empty;
		}
		else
		{
			_keys[0..capacity] = typeof(_keys[0]).init;
		}
	}

	void rehash()
	{
		import core.memory;
		size_t oldCapacity = capacity;
		auto oldKeys = _keys;
		auto oldValues = _values;
		collisionsInLength = 0;
		static if(SeparateSlotState)
		{
			auto oldStates = states;
		}
		setCapacity(cast(size_t)(capacity * getGrowthFactor(capacity)) + 1);
		// imported!"std.stdio".writeln("Rehash");

		size_t recalcLength = 0;
		foreach(i; 0..oldCapacity)
		{
			static if(SeparateSlotState)
			{
				if(getState(oldStates, i) == SlotState.alive)
				{
					uncheckedPut(oldKeys[i], oldValues[i]);
					if(++recalcLength == length)
						break;
				}
			}
			else
			{
				if(getState(oldKeys, i) == SlotState.alive)
				{
					uncheckedPut(oldKeys[i], oldValues[i]);
					if(++recalcLength == length)
						break;
				}
			}
		}
		GC.free(oldKeys);
		GC.free(oldValues);
		static if(SeparateSlotState)
		{
			GC.free(oldStates);
		}
	}

	private pragma(inline, true) size_t getHash(K key) const
	{
		static if(is(K == string))
			// return xxhash(cast(ubyte*)key.ptr, key.length) % capacity;
			return hash_64_fnv1a(key.ptr, cast(ulong)key.length) % capacity;
		else 
			// return xxhash(cast(ubyte*)&key, key.sizeof) % capacity;
			return hash_64_fnv1a(&key, cast(ulong)key.sizeof) % capacity;
	}

	ref auto opIndex(K key)
	{
		return *get(key);
	}
	const ref auto opIndex(K key)
	{
		return *get(key);
	}
	auto opBinary(string op)(const K key) const if(op == "in")
	{
		return get(key);	
	}

	auto opIndexAssign(V value, K key)
	{
		put(key, value);
		return value;
	}

	void uncheckedPut(K key, V value)
	{
		size_t hash = getHash(key);
		bool hasCollision = false;
		while(true)
		{
			SlotState st = getState(hash);
			if(st == SlotState.empty)
			{
				static if(SeparateSlotState)
					_keys[hash] = key;
				else
					_keys[hash] = SString(key.length, key.ptr);
				_values[hash] = value;
				setState(hash, SlotState.alive);
				return;
			}
			else
			{
				if(_keys[hash] == key)
				{
					_values[hash] = value;
					return;
				}
			}
			if(!hasCollision)
			{
				hasCollision = true;
				collisionsInLength++;
			}
			hash = (hash + 1) % capacity;
		}
	}
	void put(K key, V value)
	{
		if(capacity == 0)
			setCapacity(DefaultInitSize);

		if((length > UseCollisionRateThreshold && cast(float)collisionsInLength / length > CollisionFactor) ||
			(length + 1) / capacity > ResizeFactor
		)
			rehash();
		uncheckedPut(key, value);
		length++;
	}

	inout(V)* get(K key) inout
	{
		size_t hash = getHash(key);
		while(true)
		{
			if(getState(hash) == SlotState.empty)
				return null;
			if(_keys[hash] == key)
				return &_values[hash];

			hash = (hash+1) % capacity;	
		}
		return null;
	}

	K[] keys()
	{
		import core.memory;
		auto ret = cast(K*)GC.malloc(K.sizeof*length);
		size_t index = 0;
		foreach(i; 0..capacity)
		{
			if(getState(i) == SlotState.alive)
			{
				ret[index++] = _keys[i];
				if(index == length)
					break;
			}
		}
		return ret[0..length];
	}
	V[] values()
	{
		import core.memory;
		auto ret = cast(V*)GC.malloc(V.sizeof*length);
		size_t index = 0;
		foreach(i; 0..capacity)
		{
			if(getState(i) == SlotState.alive)
			{
				ret[index++] = _values[i];
				if(index == length)
					break;
			}
		}
		return ret[0..length];
	}

	void remove(K key)
	{
		const size_t precalcHash = getHash(key);
		size_t hash = precalcHash;
		
		while(true)
		{
			if(_keys[hash] == key)
			{
				size_t nexts = hash;
				while(true)
				{
					if(getHash(_keys[nexts+1]) == precalcHash)
					{
						nexts++;
						continue;
					}
					break;
				}
				if(nexts != hash)
				{
					_keys[hash] = _keys[nexts];
					values[hash] = values[nexts];
					setState(nexts, SlotState.empty);
				}
				else
					setState(hash, SlotState.empty);
				length--;
			}
		}
	}

	int opApply(scope int delegate(K key, ref V value) dg) const
	{
		int result = 0;
		int exec = 0;
		foreach(i; 0..capacity)
		{
			if(getState(i) == SlotState.alive)
			{
				exec++;
				result = dg(cast()_keys[i], cast()_values[i]);
				if (result || exec == length)
					break;
			}
		}
		return result;
	}
	int opApply(scope int delegate(ref V value) dg) const
	{
		int result = 0;
		int exec = 0;
		foreach(i; 0..capacity)
		{
			if(getState(i) == SlotState.alive)
			{
				exec++;
				result = dg(cast()_values[i]);
				if (result || exec == length)
					break;
			}
		}
		return result;
	}
	auto byKey()
	{
		static struct KeyRange
		{
			HashMap!(K, V)* map;
			size_t length, index, count;
			void popFront()
			{
				index++;
			}

			K front()
			{
				count++;
				while(map.getState(index) != SlotState.alive)
					index++;
				return map._keys[index];
			}
			bool empty() => count == length;
		}
		return KeyRange(&this, length, 0, 0);
	}
	auto byValue()
	{
		static struct ValueRange
		{
			HashMap!(K, V)* map;
			size_t length, index, count;
			void popFront() {index++;}
			V front()
			{
				count++;
				while(map.getState(index) != SlotState.alive)
					index++;
				return map._values[index];
			}
			bool empty() => count == length;
		}
		return ValueRange(&this, length, 0, 0);
	}

	auto byKeyValue()
	{
		static struct ValueRange
		{
			HashMap!(K, V)* map;
			size_t length, index, count;
			void popFront() {index++;}
			auto front()
			{
				static struct Pair
				{
					private void* keyp;
                	private void* valp;
					@property ref key() inout @trusted
					{
						return *cast(K*) keyp;
					}
					@property ref value() inout @trusted
					{
						return *cast(V*)valp;
					}
				}
				count++;
				while(map.getState(index) != SlotState.alive)
					index++;
				return Pair(&map._keys[index], &map._values[index]);
			}
			bool empty() => count == length;
		}
		return ValueRange(&this, length, 0, 0);
	}
}

private:

uint hash_32_fnv1a(const void* key, const uint len) {

    const(char)* data = cast(char*)key;
    uint hash = 0x811c9dc5;
    uint prime = 0x1000193;

    for(int i = 0; i < len; ++i) {
        hash = (hash ^ data[i]) * prime;
    }

    return hash;

} //hash_32_fnv1a

ulong hash_64_fnv1a(const void* key, const ulong len) {
    
    enum ulong prime = 0x100000001b3;
    ulong hash = 0xcbf29ce484222325;
    const(char)* data = cast(char*)key;
    
    for(int i = 0; i < len; ++i) {
        hash = (hash ^ data[i]) * prime;
    }
    
    return hash;
} 

ulong xxhash(const ubyte* data, const ulong len) 
{
	import xxhash3;

	XXH_64 xxh;
	xxh.put(data[0..len]);
	return *cast(ulong*)xxh.finish.ptr;
} 