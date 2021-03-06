import unittest
import helpers.rnw
from nesm import serializable
from helpers.serializeimport import ImportedType

suite "Nested types":
  test "Nested type from other module":
    serializable:
      type
        MyNested = object
          a: ImportedType
          b: int32
    let rnw = get_reader_n_writer()
    var o:MyNested
    o.b = 42.int32
    o.a = ImportedType(a: get_random_string(),
                       b: random(100).int32)
    o.serialize(rnw.writer)
    let d = MyNested.deserialize(rnw.reader)
    require(o.a.a.len == d.a.a.len)
    check(o.a.a == d.a.a)
    check(o.a.b == d.a.b)
    check(o.b == d.b)

#  test "Static nested type":
#   #Should cause a compile-time error
#    serializable:
#      static:
#        type
#          StaticNested = object
#            a: int32
#            b: ImportedType
##   let rrnw = get_random_reader_n_writer()
#   let nested = StaticNested.deserialize(rrnw.reader)
#    nested.serialize(rrnw.writer)
#    check(true)
