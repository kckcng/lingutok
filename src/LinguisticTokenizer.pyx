#defining NPY_NO_DEPRECATED_API NPY_1_7_API_VERSION
# cython: profile=False, embedsignature=True, boundscheck=False, wraparound=False, nonecheck=False, cdivision=True, language_level=2, language=c++
#distutils: language = c++

from __future__ import unicode_literals

from std_iostream cimport stringstream, istream, ostream
from libc.string cimport strncmp
cimport keyset
cimport key
cimport agent
cimport trie
cimport iostream
cimport base

import itertools
import struct
import warnings
from libcpp.utility cimport pair

import numpy as pynp
cimport numpy as np

from cython.parallel cimport prange
from libc.stdlib cimport malloc, free

cdef extern from "<vector>" namespace "std":
    cdef cppclass vector[T]:
        void push_back(T&) nogil except+
        size_t size()
        T& operator[](size_t)
        vector()


cdef extern from "<unordered_map>" namespace "std":
    cdef cppclass unordered_map[T, U]:
        cppclass iterator:
            pair[T, U]& operator*() nogil
            iterator operator++() nogil
            iterator operator--() nogil
            bint operator==(iterator) nogil
            bint operator!=(iterator) nogil
        unordered_map()
        unordered_map(unordered_map&)
        U& operator[](T&) nogil
        # unordered_map& operator=(unordered_map&)
        U& at(T&) nogil
        iterator begin() nogil
        void clear() nogil
        size_t count(T&) nogil
        bint empty() nogil
        iterator end() nogil
        pair[iterator, iterator] equal_range(T&) nogil
        void erase(iterator) nogil
        void erase(iterator, iterator) nogil
        size_t erase(T&) nogil
        iterator find(T&) nogil
        pair[iterator, bint] insert(pair[T, U]) nogil
        iterator insert(iterator, pair[T, U]) nogil
        void insert(input_iterator, input_iterator)
        size_t max_size() nogil
        void rehash(size_t)
        size_t size() nogil
        void swap(unordered_map&) nogil
try:
    from itertools import izip
except ImportError:
    izip = zip


DEFAULT_CACHE = base.MARISA_DEFAULT_CACHE
HUGE_CACHE = base.MARISA_HUGE_CACHE
LARGE_CACHE = base.MARISA_LARGE_CACHE
NORMAL_CACHE = base.MARISA_NORMAL_CACHE
SMALL_CACHE = base.MARISA_SMALL_CACHE
TINY_CACHE = base.MARISA_TINY_CACHE

MIN_NUM_TRIES = base.MARISA_MIN_NUM_TRIES
MAX_NUM_TRIES = base.MARISA_MAX_NUM_TRIES
DEFAULT_NUM_TRIES = base.MARISA_DEFAULT_NUM_TRIES

# MARISA_TEXT_TAIL merges last labels as zero-terminated strings. So, it is
# available if and only if the last labels do not contain a NULL character.
# If MARISA_TEXT_TAIL is specified and a NULL character exists in the last
# labels, the setting is automatically switched to MARISA_BINARY_TAIL.
TEXT_TAIL = base.MARISA_TEXT_TAIL

# MARISA_BINARY_TAIL also merges last labels but as byte sequences. It uses
# a bit vector to detect the end of a sequence, instead of NULL characters.
# So, MARISA_BINARY_TAIL requires a larger space if the average length of
# labels is greater than 8.
BINARY_TAIL = base.MARISA_BINARY_TAIL
DEFAULT_TAIL = base.MARISA_DEFAULT_TAIL


# MARISA_LABEL_ORDER arranges nodes in ascending label order.
# MARISA_LABEL_ORDER is useful if an application needs to predict keys in
# label order.
LABEL_ORDER = base.MARISA_LABEL_ORDER

# MARISA_WEIGHT_ORDER arranges nodes in descending weight order.
# MARISA_WEIGHT_ORDER is generally a better choice because it enables faster
# matching.
WEIGHT_ORDER = base.MARISA_WEIGHT_ORDER
DEFAULT_ORDER = base.MARISA_DEFAULT_ORDER


cdef class _Trie:
    cdef trie.Trie* _trie

    cdef bytes _encode_key(self, key):
        return key

    cdef _get_key(self, agent.Agent& ag):
        return ag.key().ptr()[:ag.key().length()]

    cdef int _get_id(self, agent.Agent& ag):
        return ag.key().id()

    def __init__(self, arg=None, num_tries=DEFAULT_NUM_TRIES, binary=False,
                 cache_size=DEFAULT_CACHE, order=DEFAULT_ORDER, weights=None):
        """
        ``arg`` can be one of the following:

        * an iterable with bytes keys;
        * None (if you're going to load a trie later).

        Pass a ``weights`` iterable with expected lookup frequencies
        to optimize lookup and prefix search speed.
        """

        if self._trie:
            return
        self._trie = new trie.Trie()

        byte_keys = (self._encode_key(key) for key in (arg or []))

        self._build(
            byte_keys,
            weights,
            num_tries=num_tries,
            binary=binary,
            cache_size=cache_size,
            order=order
        )

    def __dealloc__(self):
        if self._trie:
            del self._trie

    def _config_flags(self, num_tries=DEFAULT_NUM_TRIES, binary=False,
                      cache_size=DEFAULT_CACHE, order=DEFAULT_ORDER):
        if not MIN_NUM_TRIES <= num_tries <= MAX_NUM_TRIES:
            raise ValueError(
                "num_tries (which is %d) must be between between %d and %d" %
                (num_tries, MIN_NUM_TRIES, MAX_NUM_TRIES))

        binary_flag = BINARY_TAIL if binary else TEXT_TAIL
        return num_tries | binary_flag | cache_size | order

    def _build(self, byte_keys, weights=None, **options):
        if weights is None:
            weights = itertools.repeat(1.0)

        cdef char* data
        cdef float weight
        cdef keyset.Keyset *ks = new keyset.Keyset()

        try:
            for key, weight in izip(byte_keys, weights):
                ks.push_back(<char *>key, len(key), weight)
            self._trie.build(ks[0], self._config_flags(**options))
        finally:
            del ks

    def __richcmp__(self, other, int op):
        if op == 2:    # ==
            if other is self:
                return True
            elif not isinstance(other, _Trie):
                return False

            return (<_Trie>self)._equals(other)
        elif op == 3:  # !=
            return not (self == other)

        raise TypeError("unorderable types: {0} and {1}".format(
            self.__class__, other.__class__))

    cdef bint _equals(self, _Trie other) nogil:
        cdef int num_keys = self._trie.num_keys()
        cdef base.NodeOrder node_order = self._trie.node_order()
        if (other._trie.num_keys() != num_keys or
            other._trie.node_order() != node_order):
            return False

        cdef agent.Agent ag1, ag2
        ag1.set_query(b"")
        ag2.set_query(b"")
        cdef int i
        cdef key.Key key1, key2
        for i in range(num_keys):
            self._trie.predictive_search(ag1)
            other._trie.predictive_search(ag2)
            key1 = ag1.key()
            key2 = ag2.key()
            if (key1.length() != key2.length() or
                strncmp(key1.ptr(), key2.ptr(), key1.length()) != 0):
                return False
        return True

    def __iter__(self):
        return self.iterkeys()

    def __len__(self):
        return self._trie.num_keys()

    def __contains__(self, key):
        cdef bytes _key = self._encode_key(key)
        return self._contains(_key)

    cdef bint _contains(self, bytes key):
        cdef agent.Agent ag
        ag.set_query(key, len(key))
        return self._trie.lookup(ag)

    def read(self, f):
        """Read a trie from an open file.

        :param file f: a "real" on-disk file object. Passing a *file-like*
                       object would result in an error.

        .. deprecated:: 0.7.3

           The method will be removed in version 0.8.0. Please use
           :meth:`load` instead.
        """
        warnings.warn("Trie.save is deprecated and will "
                      "be removed in marisa_trie 0.8.0. Please use "
                      "Trie.load instead.", DeprecationWarning)
        self._trie.read(f.fileno())
        return self

    def write(self, f):
        """Write a trie to an open file.

        :param file f: a "real" on-disk file object. Passing a *file-like*
                       object would result in an error.

        .. deprecated:: 0.7.3

           The method will be removed in version 0.8.0. Please use
           :meth:`save` instead.
        """
        warnings.warn("Trie.write is deprecated and will "
                      "be removed in marisa_trie 0.8.0. Please use "
                      "Trie.save instead.", DeprecationWarning)
        self._trie.write(f.fileno())

    def save(self, path):
        """Save a trie to a specified path."""
        with open(path, 'w') as f:
            self._trie.write(f.fileno())

    def load(self, path):
        """Load a trie from a specified path."""
        with open(path, 'r') as f:
            self._trie.read(f.fileno())
        return self

    cpdef bytes tobytes(self) except +:
        """Return raw trie content as bytes."""
        cdef stringstream stream
        iostream.write((<ostream *> &stream)[0], self._trie[0])
        cdef bytes res = stream.str()
        return res

    cpdef frombytes(self, bytes data) except +:
        """Load a trie from raw bytes generated by :meth:`tobytes`."""
        cdef stringstream* stream = new stringstream(data)
        try:
            iostream.read((<istream *> stream)[0], self._trie)
        finally:
            del stream
        return self

    def __reduce__(self):
        return self.__class__, (), self.tobytes()

    __setstate__ = frombytes

    def mmap(self, path):
        """Memory map the content of a trie stored in a file.

        This allows to query trie without loading it fully in memory.
        """
        import sys
        str_path = path.encode(sys.getfilesystemencoding())
        cdef char* c_path = str_path
        self._trie.mmap(c_path)
        return self

    def iterkeys(self, prefix=None):
        """
        Return an iterator over trie keys starting with a given ``prefix``.
        """
        cdef agent.Agent ag
        cdef bytes b_prefix = b''
        if prefix is not None:
            b_prefix = self._encode_key(prefix)
        ag.set_query(b_prefix, len(b_prefix))

        while self._trie.predictive_search(ag):
            yield self._get_key(ag)

    cpdef list keys(self, prefix=None):
        """Return a list of trie keys starting with a given ``prefix``."""
        # non-generator inlined version of iterkeys()
        cdef list res = []
        cdef bytes b_prefix = b''
        if prefix is not None:
            b_prefix = self._encode_key(prefix)
        cdef agent.Agent ag
        ag.set_query(b_prefix, len(b_prefix))

        while self._trie.predictive_search(ag):
            res.append(self._get_key(ag))

        return res

    def has_keys_with_prefix(self, prefix=""):
        """
        Return ``True`` if any key in the trie begins with ``prefix``.

        .. deprecated:: 0.7.3

           The method will be removed in version 0.8.0. Please use
           :meth:`iterkeys` instead.
        """
        warnings.warn("Trie.has_keys_with_prefix is deprecated and will "
                      "be removed in marisa_trie 0.8.0. Please use "
                      "Trie.iterkeys instead.", DeprecationWarning)

        cdef agent.Agent ag
        cdef bytes b_prefix = self._encode_key(prefix)
        ag.set_query(b_prefix, len(b_prefix))
        return self._trie.predictive_search(ag)


cdef class _UnicodeKeyedTrie(_Trie):
    """
    MARISA-trie wrapper for unicode keys.
    """
    cdef bytes _encode_key(self, key):
        return key.encode('utf8')

    cdef _get_key(self, agent.Agent& ag):
        return <unicode>_Trie._get_key(self, ag).decode('utf8')


cdef class Trie(_Trie):
    """A trie mapping unicode keys to auto-generated unique IDs."""

    # key_id method is not in _Trie because it won't work for BytesTrie
    cpdef int key_id(self, unicode key) except -1:
        """Return an ID generated for a given ``key``.

        :raises KeyError: if key is not present in this trie.
        """
        cdef bytes _key = <bytes>key.encode('utf8')
        cdef int res = self._key_id(_key)
        if res == -1:
            raise KeyError(key)
        return res

    def __getitem__(self, unicode key):
        return self.key_id(key)

    def get(self, key, default=None):
        """
        Return an ID for a given ``key`` or ``default`` if ``key`` is
        not present in this trie.
        """
        cdef bytes b_key
        cdef int res

        if isinstance(key, unicode):
            b_key = <bytes>(<unicode>key).encode('utf8')
        else:
            b_key = key

        res = self._key_id(b_key)
        if res == -1:
            return default
        return res

    cpdef restore_key(self, int index):
        """Return a key corresponding to a given ID."""
        cdef agent.Agent ag
        ag.set_query(index)
        try:
            self._trie.reverse_lookup(ag)
        except KeyError:
            raise KeyError(index)
        return self._get_key(ag)

    cdef int _key_id(self, char* key):
        cdef bint res
        cdef agent.Agent ag
        ag.set_query(key)
        res = self._trie.lookup(ag)
        if not res:
            return -1
        return ag.key().id()

    def iter_prefixes(self, unicode key):
        """
        Return an iterator of all prefixes of a given key.
        """
        cdef bytes b_key = <bytes>key.encode('utf8')
        cdef agent.Agent ag
        ag.set_query(b_key)

        while self._trie.common_prefix_search(ag):
            yield self._get_key(ag)

    def prefixes(self, unicode key):
        """
        Return a list with all prefixes of a given key.
        """
        # this an inlined version of ``list(self.iter_prefixes(key))``

        cdef list res = []
        cdef bytes b_key = <bytes>key.encode('utf8')
        cdef agent.Agent ag
        ag.set_query(b_key)

        while self._trie.common_prefix_search(ag):
            res.append(self._get_key(ag))
        return res

    cdef vector[int] _prefixes_id(self, bytes key):
        """
        Return a list with all prefixes of a given key.
        """
        # this an inlined version of ``list(self.iter_prefixes(key))``

        cdef vector[int] res
        cdef agent.Agent ag
        ag.set_query(key, len(key))

        while self._trie.common_prefix_search(ag):
            res.push_back(self._get_id(ag))
        return res

    def iteritems(self, unicode prefix=""):
        """
        Return an iterator over items that have a prefix ``prefix``.
        """
        cdef bytes b_prefix = <bytes>prefix.encode('utf8')
        cdef agent.Agent ag
        ag.set_query(b_prefix)

        while self._trie.predictive_search(ag):
            yield self._get_key(ag), ag.key().id()

    def items(self, unicode prefix=""):
        # inlined for speed
        cdef list res = []
        cdef bytes b_prefix = <bytes>prefix.encode('utf8')
        cdef agent.Agent ag
        ag.set_query(b_prefix)

        while self._trie.predictive_search(ag):
            res.append((self._get_key(ag), ag.key().id()))

        return res




















from pkg_resources import resource_filename

from libcpp.vector cimport vector

package_name = 'LinguisticTokenizer'
import os.path
import json


def get_file(x):
    return resource_filename(package_name, 'resources/' + x)

    

single_words_only = set()
single_words_any  = set()
irreguler_exceptions = {}



prefixes = set()

# hashmap<str,hashset>
suffixes = {}
roots = set()

all_parts = {}
cdef int part_id = 0
all_parts_list = []

all_vocabs = {}
cdef int vocab_id = 0
all_vocabs_list = []



no_prefixed_by_of = {}
only_suffixed_by_of = {}
no_suffixed_by_of = {}
no_suffixed_by_of_roots = {}
no_suffixed_by_of_nonroots = {}



cdef bint adjacent_violate(s_Part A_part, s_Part B_part):
    cdef bint A_is_root = A_part.form == ROOT
    
    A = all_parts_list[A_part.content]
    B = all_parts_list[B_part.content]

    if A_part.merge_mode == MERGE_MODE_SINGLE and B_part.merge_mode == MERGE_MODE_SINGLE:
        return False

    if B in no_prefixed_by_of and A in no_prefixed_by_of[B]:
        return True
    if A in only_suffixed_by_of and B not in only_suffixed_by_of[A]:
        return True
    if A_is_root:
        if A in no_suffixed_by_of_roots and (B in no_suffixed_by_of_roots[A] or len(no_suffixed_by_of_roots[A]) == 0):
            return True
    elif A in no_suffixed_by_of_nonroots and (B in no_suffixed_by_of_nonroots[A] or len(no_suffixed_by_of_nonroots[A]) == 0):
        return True
    if A in no_suffixed_by_of and B in no_suffixed_by_of[A]:
        return True
    return False

cdef bint adjacent_violate_str(str A, str B, bint A_is_root):

    if B in no_prefixed_by_of and A in no_prefixed_by_of[B]:
        return True
    if A in only_suffixed_by_of and B not in only_suffixed_by_of[A]:
        return True
    if A_is_root:
        if A in no_suffixed_by_of_roots and (B in no_suffixed_by_of_roots[A] or len(no_suffixed_by_of_roots[A]) == 0):
            return True
    elif A in no_suffixed_by_of_nonroots and (B in no_suffixed_by_of_nonroots[A] or len(no_suffixed_by_of_nonroots[A]) == 0):
        return True
    if A in no_suffixed_by_of and B in no_suffixed_by_of[A]:
        return True
    return False


                
cdef extern from "Python.h":
    char* PyUnicode_AsUTF8(object unicode)

    
cdef struct AB:
    int A
    int B
    char* morphed
    int B_length
    int morphed_length
    long key
    float score

cdef struct ABC:
    int A
    int B
    int C
    char* morphed
    long key
    float score
    

stay_alive = []

cdef long hash_string(str s):
    return hash(s)


cdef vector[AB] get_morphed_suffixes_merge_suffixes(int min_left = 1):
    cdef int len_s, len_p
    cdef float score
    cdef vector[AB] ret
    for suffix, prefixers in suffixes.items():
        for p in prefixers:
            if not p:
                continue
            for s in suffixes:
                if s not in all_parts or s in irreguler_exceptions:
                    continue
                if s.endswith(p):
                    A = s
                    B = suffix
                        
                    if (A in single_words_any or A in single_words_only) != (B in single_words_any or B in single_words_only):
                        continue
                    if adjacent_violate_str(A, B, False):
                        continue
                        
                    len_s = len(s)
                    len_p = len(p)
                        
                    if len_s - len_p < min_left:
                        continue
                        
                    overlapped = s[len_s-len_p:]
                    
                    if overlapped == 'e' or overlapped == 'o' or overlapped == 'y':
                        score = 0
                    else:
                        score = -len_p
                    
                    
                    new_morphed = s[:len_s-len_p]+suffix
                    stay_alive.append(new_morphed)
                    ret.push_back( 
                        AB(
                            all_parts[A],
                            all_parts[B], 
                            PyUnicode_AsUTF8(new_morphed), 
                            len(B), 
                            len(new_morphed), 
                            hash_string(new_morphed), 
                            score 
                        )
                    )
                    '''
    int A
    int B
    char* morphed
    int B_length
    int morphed_length
    long key
    float score
    '''
                
    return ret

cdef vector[AB] get_morphed_roots_merge_suffixes(int min_left = 1):
    cdef int len_s, len_p
    cdef float score
    cdef vector[AB] ret
    
    for suffix, prefixers in suffixes.items():
        for p in prefixers:
            if not p:
                continue
            for s in roots:
                if s not in all_parts or s in irreguler_exceptions:
                    continue
                if s.endswith(p):
                    A = s
                    B = suffix
                        
                    if (A in single_words_any or A in single_words_only) != (B in single_words_any or B in single_words_only):
                        continue
                    if adjacent_violate_str(A, B, True):
                        continue
                        
                    len_s = len(s)
                    len_p = len(p)
                        
                    if len_s - len_p < min_left:
                        continue

                    overlapped = s[len_s-len_p:]
                    
                    if overlapped == 'e' or overlapped == 'o' or overlapped == 'y':
                        score = 0
                    else:
                        score = -len_p
                        
                    new_morphed = s[:len_s-len_p]+suffix
                    stay_alive.append(new_morphed)
                    ret.push_back( 
                        AB(
                            all_parts[A],
                            all_parts[B], 
                            PyUnicode_AsUTF8(new_morphed), 
                            len(B), 
                            len(new_morphed), 
                            hash_string(new_morphed), 
                            score 
                        )
                    )

    return ret


cdef class ABCResult:
    cdef ABC content
    def __init__(self, ABC content):
        self.content = content


def mix_two_morphed(vector[AB] h, vector[AB] k, int min_left):
    cdef AB ab, bc
    cdef int A, B, C, D, morphed_length, B_length
    cdef unordered_map[int, vector[AB]] temp_index
    cdef vector[AB] bucket

    
    for i in range(<int>k.size()):
        ab = k[i]
        B = ab.B
        if ab.morphed_length - ab.B_length < min_left:
            continue

        if temp_index.find(B) == temp_index.end():
            temp_index[B] = vector[AB]()
            
        temp_index[B].push_back(ab)


    for i in range(<int>h.size()):
        ab = h[i]
        A = ab.A
        B = ab.B
        morphed_length = ab.morphed_length
        B_length = ab.B_length
        
        if temp_index.find(B) != temp_index.end():
            bucket = temp_index[B]
            for j in range(<int>bucket.size()):
                bc = bucket[j]
                C = bc.A
                D = bc.B


                new_morphed = (
                    (<bytes>ab.morphed).decode()[:morphed_length-B_length] + 
                    (<bytes>bc.morphed).decode()
                    )

                stay_alive.append(new_morphed)
                yield ABCResult(
                    ABC(
                        A,
                        B,
                        D, 
                        PyUnicode_AsUTF8(new_morphed), 
                        hash_string(new_morphed), 
                        ab.score + bc.score 
                    )
                )

                
                

for e in (
    no_prefixed_by_of,
    only_suffixed_by_of,
    no_suffixed_by_of_roots,
    no_suffixed_by_of_nonroots,
    no_suffixed_by_of
):
    for k, v in list(e.items()):
        if k not in prefixes and k not in roots and k not in suffixes:
            print('no', k)
            del e[k]
        for c in list(v):
            if not c:
                v.remove(c)
                continue
            if c not in prefixes and c not in roots and c not in suffixes:
                print('not found:', c)
                v.remove(c)
                
                
                
                














cdef int MERGE_MODE_NORMAL = 0
cdef int MERGE_MODE_BOTH   = 1
cdef int MERGE_MODE_SINGLE = 2
    
cdef int PREFIX = 1
cdef int ROOT = 2
cdef int SUFFIX = 3
    
'''
cdef class Part():
    cdef int contents
    cdef int form
    cdef bint merge_mode

    def __init__(self, contents, form, merge_mode):
        self.contents = contents
        self.form = form
        self.merge_mode = merge_mode
    
cdef class Parts():
    cdef list contents
    cdef float score

    def __init__(self, contents, score):
        self.contents = contents
        self.score = score
'''
cdef struct s_Part:
    int content
    int mode
    int merge_mode
    
cdef struct s_Parts:
    vector[s_Part] contents
    float score
    
ctypedef s_Part Part
ctypedef s_Parts Parts
ctypedef vector[Part] vector_Part
ctypedef vector[Parts] vector_Parts


cdef float ROOT_PUNISHMENT = 0.5

'''
    e = 'abs'
    key = hash_string(e)                      # The key from the prefix
    bucket = get_bucket(key)
    bucket.push_back(Parts(vec_part, 0))
    trie_values[key] = bucket                 # what we want from prefixes

    ...

    for e in trie.prefixes('absolutely'):
        key = hash_string(e.decode())
        tire_key = tire._key_id(e.decode())   


    ...

    #  cdef vector[int] _prefixes_id(self, bytes key):

    cdef vector[int] prefixes_in_trie_ids = trie._prefixes_id('absolutely')

    cdef int trie_id
    for i in range(<int>prefixes_in_trie_ids.size()):
        trie_id = prefixes_in_trie_ids[i]     # Trie internal id

    ...

    
    cdef unordered_map[int, vector[Parts]] true_trie_values


    for e in trie:
        key = hash_string(e.decode())
        trie_id = trie[e]
        true_trie_values[trie_id] = trie_values[key]








'''

def get_trie_values(k):
    return trie_values[k]





cdef void ensure_bucket(long key):
    global trie_values
    cdef vector[Parts] bucket
    if trie_values.find(key) == trie_values.end():
        bucket = vector[Parts]()
        trie_values[key] = bucket
        

cdef Part get_part(int content, int mode, int merge_mode):
    global seen
    cdef int key = content*7 + mode*3 + merge_mode
    if seen.find(key) != seen.end():
        return seen[key]

    cdef Part ret
    ret.content = content
    ret.mode = mode
    ret.merge_mode = merge_mode
    seen[key] = ret
    return ret


cdef unordered_map[long, vector[Parts]] trie_values
cdef unordered_map[int, vector[Parts]] true_trie_values
cdef unordered_map[int, s_Part] seen

def gen():
    cdef vector_Parts* bucket
    cdef vector_Part vec_part
    cdef int k, n, i
    cdef long key

    print('Loading prefixes')
    for e in prefixes:
        k = all_parts[e]
        key = hash_string(e)
        ensure_bucket(key)
        #print('%-20d: %s'%(key, e))
        bucket = &trie_values[key]
        vec_part = vector_Part()
        vec_part.push_back(get_part(k, PREFIX, e in single_words_any or e in single_words_only))
        bucket.push_back(Parts(vec_part, 0))
        assert len(e) > 0
        assert trie_values[key].size() > 0
        yield e.encode()

    print('Loading roots')
    for e in roots:
        k = all_parts[e]
        key = hash_string(e)
        ensure_bucket(key)
        bucket = &trie_values[key]
        vec_part = vector_Part()
        vec_part.push_back(get_part(k, ROOT, e in single_words_any or e in single_words_only))
        bucket.push_back(Parts(vec_part, -ROOT_PUNISHMENT))
        assert len(e) > 0
        assert trie_values[key].size() > 0
        yield e.encode()

    print('Loading suffixes')
    for e in suffixes:
        k = all_parts[e]
        key = hash_string(e)
        ensure_bucket(key)
        bucket = &trie_values[key]
        vec_part = vector_Part()
        vec_part.push_back(get_part(k, SUFFIX, e in single_words_any or e in single_words_only))
        bucket.push_back(Parts(vec_part, 0))
        assert len(e) > 0
        assert trie_values[key].size() > 0
        yield e.encode()
        
    print('Loading morphed_suffixes_merge_suffixes')
    cdef vector[AB] morphed_suffixes_merge_suffixes = get_morphed_suffixes_merge_suffixes()
    print('Loading morphed_roots_merge_suffixes')
    cdef vector[AB] morphed_roots_merge_suffixes = get_morphed_roots_merge_suffixes()
    
    cdef AB ret
    cdef ABC ret2

    print('Processing morphed_suffixes_merge_suffixes')
    for i in range(<int>morphed_suffixes_merge_suffixes.size()):
        ret = morphed_suffixes_merge_suffixes[i]
        ensure_bucket(ret.key)
        bucket = &trie_values[ret.key]
        
        vec_part = vector_Part()
        vec_part.push_back(get_part(ret.A, SUFFIX, False))
        vec_part.push_back(get_part(ret.B, SUFFIX, False))
        bucket.push_back(Parts(vec_part, ret.score - 1))
        
        yield (<bytes>ret.morphed)

    print('Processing morphed_roots_merge_suffixes')
    for i in range(<int>morphed_roots_merge_suffixes.size()):
        ret = morphed_roots_merge_suffixes[i]
        ensure_bucket(ret.key)
        bucket = &trie_values[ret.key]
        
        vec_part = vector_Part()
        vec_part.push_back(get_part(ret.A, ROOT, False))
        vec_part.push_back(get_part(ret.B, SUFFIX, False))
        bucket.push_back(Parts(vec_part, ret.score-ROOT_PUNISHMENT - 1))
        
        yield (<bytes>ret.morphed)


    cdef ABCResult ABC_result
    print('Loading morphed_roots_merge_suffixes mix morphed_suffixes_merge_suffixes')
    for ABC_result in mix_two_morphed(morphed_suffixes_merge_suffixes, morphed_suffixes_merge_suffixes, 1):
        ret2 = ABC_result.content
        ensure_bucket(ret2.key)
        bucket = &trie_values[ret2.key]
        vec_part = vector_Part()
        vec_part.push_back(get_part(ret2.A, SUFFIX, False))
        vec_part.push_back(get_part(ret2.B, SUFFIX, False))
        vec_part.push_back(get_part(ret2.C, SUFFIX, False))
        bucket.push_back(Parts(vec_part, ret2.score - 2))
        
        yield (<bytes>ret2.morphed)

    print('Loading morphed_roots_merge_suffixes mix morphed_suffixes_merge_suffixes')
    for ABC_result in mix_two_morphed(morphed_roots_merge_suffixes, morphed_suffixes_merge_suffixes, 2):

        ret2 = ABC_result.content
        ensure_bucket(ret2.key)
        bucket = &trie_values[ret2.key]
        vec_part = vector_Part()
        vec_part.push_back(get_part(ret2.A, ROOT, False))
        vec_part.push_back(get_part(ret2.B, SUFFIX, False))
        vec_part.push_back(get_part(ret2.C, SUFFIX, False))
        bucket.push_back(Parts(vec_part, ret2.score-ROOT_PUNISHMENT - 2))
        
        yield (<bytes>ret2.morphed)


from cython.operator cimport dereference as deref, preincrement as inc

def load_data():
    global vocab_id, part_id
    fn = get_file('words2.txt')
    with open(fn) as f:
        words = f.read()
        

    with open(get_file('single_words.txt')) as f:
        for line in f:
            line = line.strip()
            if line.startswith('#'):
                continue
            if line.startswith('*'):
                single_words_any.add(line[1:])
                continue
                
            if not line:
                continue

            single_words_only.add(line)
    with open(get_file('irreguler_exceptions.json')) as f:
        irreguler_exceptions.update(json.load(f))


    with open(get_file('words2.txt')) as f:
        for line in f:
            line = line.strip()
            if line.startswith('#'):
                continue
            splitted = ['','','']
            for i, e in enumerate(line.split('|')):
                splitted[i] = e
                
            a,b,c = splitted
            
            
            token_id = 0
            
            for e in a.split(','):
                if e in irreguler_exceptions:
                    if len(a.split(',')) != 1:
                        raise
                    # this will be decoded like normal token, but decomposed later
                    # so no token_id
                    token_id = -1
                    break
                if e in all_vocabs:
                    token_id = all_vocabs[e]
                    
            if token_id == 0:
                vocab_id += 1
                token_id = vocab_id
            
            

            index = 0
            for e in a.split(','):
                E = e.strip('-')
                if E not in all_parts:
                    all_parts[E] = part_id
                    all_parts_list.append(E)
                    part_id += 1
                
                
                
                assert '+' not in e
                index += 1
                if not e:
                    continue
                    
                if token_id > 0:
                    all_vocabs[e] = token_id - 1
                    all_vocabs_list.append(e)
                    
                    
                if e.startswith('-'):
                    e = e[1:]
                    if e in single_words_only:
                        single_words_any.add(e)
                        single_words_only.remove(e)
                    if e not in suffixes:
                        suffixes[e] = set()
                        
                        if not c:
                            suffixes[e].add('')
                    if b and index == 1:
                        for bb in b.split(','):
                            bb = bb.strip()
                            assert bb.startswith('+')
                            suffixes[e].add(bb[1:])
                elif e.endswith('-'):
                    e = e[:len(e)-1]
                    if e in single_words_only:
                        single_words_any.add(e)
                        single_words_only.remove(e)
                        
                    prefixes.add(e)
                else:
                    roots.add(e)
    for e in single_words_only:
        assert '-' not in e
        assert e
        if e not in all_parts:
            all_parts[e] = part_id
            all_parts_list.append(e)
            part_id += 1
            if e not in roots:
                roots.add(e)
            
    rules = {}
    with open(get_file('rules.py')) as f:
        exec(f.read(), rules)

    # A no prefixed by B
    # all roots
    no_prefixed_by_of.update(rules['expand_allowed_reverse'])

    # A only suffixed by B
    only_suffixed_by_of.update({k:v or set() for k, v in rules['expand_allowed'].items()})
    rules['expand_allowed'].clear()
        
    # A no suffixed by B
    no_suffixed_by_of.update(rules['pairs_exceptions'])

    # A no suffixed by B (root)
    no_suffixed_by_of_roots.update({
        k[0]: set(v.split(','))
        for k, v in rules['expand_exceptions'].items() if k[1]
    })

    # A no suffixed by B (non-root)
    no_suffixed_by_of_nonroots.update({
        k[0]: set(v.split(','))
        for k, v in rules['expand_exceptions'].items() if not k[1]
    })
            
    rules['expand_exceptions'].clear()

def true_trie_values_to_np():
    cdef unordered_map[int, vector[Parts]].iterator it = true_trie_values.begin()
    cdef unordered_map[int, vector[Parts]].iterator end = true_trie_values.end()
        
    cdef Py_ssize_t key, i, j, size, size2
    cdef vector[Parts] vector_parts
    cdef Parts parts
    cdef Part part
    cdef vector[np.int32_t] buffer 
    while it != end:
        key = deref(it).first
        vector_parts = deref(it).second
        size = vector_parts.size()

        assert size > 0, "% zero size (:1)"%key

        buffer.push_back(key)
        buffer.push_back(size)


        for i in range(size):
            parts = vector_parts[i]
            size2 = parts.contents.size()
            assert size2 > 0, "% zero size (:2)"%key

            buffer.push_back(<int>parts.score*100)
            buffer.push_back(size2)

            for j in range(size2):
                part = parts.contents[j]
                buffer.push_back(part.content)
                buffer.push_back(part.mode)
                buffer.push_back(part.merge_mode)

        inc(it)


    cdef np.ndarray[np.int32_t] data = pynp.empty(buffer.size(), dtype=pynp.int32)
    for i in prange(data.shape[0], nogil=True):
        data[i] = buffer[i]

    return data


def generate_trie(str path, str name):
    global stay_alive

    load_data() 

    cdef Py_ssize_t trie_id
    cdef long key

    trie = Trie(gen())
    del stay_alive

    trie.save(os.path.join(path, name+'.trie'))


    cdef unordered_map[long, vector[Parts]].iterator it = trie_values.begin()
    cdef unordered_map[long, vector[Parts]].iterator end = trie_values.end()
    cdef int size
    cdef vector[Parts] val
    while it != end:
        key = deref(it).first
        val = deref(it).second
        assert val.size() > 0, "trie_values"
        assert trie_values[key].size() > 0, "trie_values!"

        inc(it)



    for e in trie:
        key = hash_string(e.decode())
        trie_id = trie[e.decode()]
        
        if trie_values.find(key) == trie_values.end():
            raise Exception('key `%s` not found: %r'%(key, e.decode()))
            
        assert trie_values[key].size() > 0, "trie_values 2" 
        true_trie_values[trie_id] = trie_values[key]
        assert true_trie_values[trie_id].size() > 0, "true_trie_values"

    data = true_trie_values_to_np()

    with open(os.path.join(path, name+'.vals'), 'wb') as f:
        f.write(data.data.tobytes())

    '''
    read back:
    pynp.frombuffer(f.read(), dtype=pynp.int32)
    '''
    
    for k, v in list(no_prefixed_by_of.items()):
        if k: no_prefixed_by_of[all_parts[k]] = {all_parts[c] for c in v if c}
    for k, v in list(only_suffixed_by_of.items()):
        if k: only_suffixed_by_of[all_parts[k]] = {all_parts[c] for c in v if c}
    for k, v in list(no_suffixed_by_of_roots.items()):
        if k: no_suffixed_by_of_roots[all_parts[k]] = {all_parts[c] for c in v if c}
    for k, v in list(no_suffixed_by_of_nonroots.items()):
        if k: no_suffixed_by_of_nonroots[all_parts[k]] = {all_parts[c] for c in v if c}
    for k, v in list(no_suffixed_by_of.items()):
        if k: no_suffixed_by_of[all_parts[k]] = {all_parts[c] for c in v if c}
            