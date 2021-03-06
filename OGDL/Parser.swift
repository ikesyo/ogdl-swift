//
//  Parser.swift
//  OGDL
//
//  Created by Justin Spahr-Summers on 2015-01-07.
//  Copyright (c) 2015 Carthage. All rights reserved.
//

import Foundation
import Either
import Madness
import Prelude

/// Returns a parser which parses one character from the given set.
internal prefix func % (characterSet: NSCharacterSet) -> Parser<String>.Function {
	return { string in
		let scalars = string.unicodeScalars

		if let scalar = first(scalars) {
			if characterSet.longCharacterIsMember(scalar.value) {
				return (String(scalar), String(dropFirst(scalars)))
			}
		}

		return nil
	}
}

/// Removes the characters in the given string from the character set.
internal func - (characterSet: NSCharacterSet, characters: String) -> NSCharacterSet {
	let mutableSet = characterSet.mutableCopy() as NSMutableCharacterSet
	mutableSet.removeCharactersInString(characters)
	return mutableSet
}

/// Removes characters in the latter set from the former.
internal func - (characterSet: NSCharacterSet, subtrahend: NSCharacterSet) -> NSCharacterSet {
	let mutableSet = characterSet.mutableCopy() as NSMutableCharacterSet
	mutableSet.formIntersectionWithCharacterSet(subtrahend.invertedSet)
	return mutableSet
}

/// Optional matching operator.
postfix operator |? {}

/// Matches zero or one occurrence of the given parser.
internal postfix func |? <T>(parser: Parser<T>.Function) -> Parser<T?>.Function {
	return (parser * (0..<2)) --> first
}

private let char_control = NSCharacterSet.controlCharacterSet()
private let char_text = char_control.invertedSet - NSCharacterSet.newlineCharacterSet()
private let char_word = char_text - ",()" - NSCharacterSet.whitespaceCharacterSet()
private let char_space = NSCharacterSet.whitespaceCharacterSet()
private let char_break = NSCharacterSet.newlineCharacterSet()

// TODO: Use this somewhere.
private let char_end = char_control - NSCharacterSet.whitespaceAndNewlineCharacterSet()

private let wordStart: Parser<String>.Function = %(char_word - "#'\"")
private let wordChars: Parser<String>.Function = (%(char_word - "'\""))* --> { strings in join("", strings) }
private let word: Parser<String>.Function = wordStart ++ wordChars --> (+)
private let br: Parser<()>.Function = ignore(%char_break)
private let eof: Parser<()>.Function = { $0 == "" ? ((), "") : nil }
private let comment: Parser<()>.Function = ignore(%"#" ++ (%char_text)+ ++ (br | eof))
// TODO: Escape sequences.
private let singleQuotedChars: Parser<String>.Function = (%(char_text - "'"))* --> { strings in join("", strings) }
private let singleQuoted: Parser<String>.Function = ignore(%"'") ++ singleQuotedChars ++ ignore(%"'")
private let doubleQuotedChars: Parser<String>.Function = (%(char_text - "\""))* --> { strings in join("", strings) }
private let doubleQuoted: Parser<String>.Function = ignore(%"\"") ++ doubleQuotedChars ++ ignore(%"\"")
private let quoted: Parser<String>.Function = singleQuoted | doubleQuoted
private let requiredSpace: Parser<()>.Function = ignore((comment | %char_space)+)
private let optionalSpace: Parser<()>.Function = ignore((comment | %char_space)*)
private let separator: Parser<()>.Function = ignore(optionalSpace ++ %"," ++ optionalSpace)

private let value: Parser<String>.Function = word | quoted

/// A function taking an Int and returning a parser which parses at least that many
/// indentation characters.
func indentation(n: Int) -> Parser<Int>.Function {
	return (%char_space * (n..<Int.max)) --> { $0.count }
}

// MARK: Generic combinators
// FIXME: move these into Madness.

/// Delays the evaluation of a parser so that it can be used in a recursive grammar without deadlocking Swift at runtime.
private func lazy<T>(parser: () -> Parser<T>.Function) -> Parser<T>.Function {
	return { parser()($0) }
}

/// Returns a parser which produces an array of parse trees produced by `parser` interleaved with ignored parses of `separator`.
///
/// This is convenient for e.g. comma-separated lists.
private func interleave<T, U>(separator: Parser<U>.Function, parser: Parser<T>.Function) -> Parser<[T]>.Function {
	return (parser ++ (ignore(separator) ++ parser)*) --> { [$0] + $1 }
}

private func foldr<S: SequenceType, Result>(sequence: S, initial: Result, combine: (S.Generator.Element, Result) -> Result) -> Result {
	var generator = sequence.generate()
	return foldr(&generator, initial, combine)
}

private func foldr<G: GeneratorType, Result>(inout generator: G, initial: Result, combine: (G.Element, Result) -> Result) -> Result {
	return generator.next().map { combine($0, foldr(&generator, initial, combine)) } ?? initial
}

private func | <T, U> (left: Parser<T>.Function, right: String -> U) -> Parser<Either<T, U>>.Function {
	return left | { (right($0), $0) }
}

private func | <T> (left: Parser<T>.Function, right: String -> T) -> Parser<T>.Function {
	return left | { (right($0), $0) }
}

private func flatMap<T, U>(x: [T], f: T -> [U]) -> [U] {
	return reduce(lazy(x).map(f), [], +)
}

// MARK: OGDL

private let children: Parser<[Node]>.Function = lazy { group | (element --> { elem in [ elem ] }) }

private let element = lazy { value ++ (optionalSpace ++ children)|? --> { value, children in Node(value: value, children: children ?? []) } }

// TODO: See Carthage/ogdl-swift#3.
private let block: Int -> Parser<()>.Function = { n in const(nil) }

/// Parses a single descendent element.
///
/// This is an element which may be an in-line descendent, and which may further have in-line descendents of its own.
private let descendent = value --> { Node(value: $0) }

/// Parses a sequence of hierarchically descending elements, e.g.:
///
///		x y z # => Node(x, [Node(y, Node(z))])
public let descendents: Parser<Node>.Function = interleave(requiredSpace, descendent) --> {
	foldr(dropLast($0), last($0)!) { $0.nodeByAppendingChildren([ $1 ]) }
}

/// Parses a chain of descendents, optionally ending in a group.
///
///		x y (u, v) # => Node(x, [ Node(y, [ Node(u), Node(v) ]) ])
private let descendentChain: Parser<Node>.Function = (descendents ++ ((optionalSpace ++ group) | const([]))) --> uncurry(Node.nodeByAppendingChildren)

/// Parses a sequence of adjacent sibling elements, e.g.:
///
///		x, y z, w (u, v) # => [ Node(x), Node(y, Node(z)), Node(w, [ Node(u), Node(v) ]) ]
public let adjacent: Parser<[Node]>.Function = lazy { interleave(separator, descendentChain) }

/// Parses a parenthesized sequence of sibling elements, e.g.:
///
///		(x, y z, w) # => [ Node(x), Node(y, Node(z)), Node(w) ]
private let group = lazy { ignore(%"(") ++ optionalSpace ++ adjacent ++ optionalSpace ++ ignore(%")") }

private let subgraph: Int -> Parser<[Node]>.Function = { n in
	(descendents ++ lines(n + 1) --> { [ $0.nodeByAppendingChildren($1) ] }) | adjacent
}

private let line: Int -> Parser<[Node]>.Function = fix { line in
	{ n in
		// TODO: block parsing: ignore(%char_space+ ++ block(n))|?) ++
		// See Carthage/ogdl-swift#3.
		indentation(n) >>- { n in
			subgraph(n) ++ optionalSpace
		}
	}
}

private let followingLine: Int -> Parser<[Node]>.Function = { n in (ignore(comment | br)+ ++ line(n)) }
private let lines: Int -> Parser<[Node]>.Function = { n in
	(line(n)|? ++ followingLine(n)*) --> { ($0 ?? []) + flatMap($1, id) }
}

/// Parses a textual OGDL graph into a list of nodes (and their descendants).
///
/// Example:
///
///   let nodes = parse(graph, "foo (bar, buzz baz)")
public let graph: Parser<[Node]>.Function = ignore(comment | br)* ++ (lines(0) | adjacent) ++ ignore(comment | br)*
