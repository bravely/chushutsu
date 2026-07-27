defmodule Chushutsu.TreeTest do
  use ExUnit.Case, async: true

  alias Chushutsu.Tree

  describe "build/2 and basic accessors" do
    test "creates a detached element" do
      {tree, id} = Tree.new() |> Tree.create("p")

      assert Tree.tag(tree, id) == "p"
      assert Tree.text(tree, id) == nil
      assert Tree.tail(tree, id) == nil
      assert Tree.children(tree, id) == []
      assert Tree.parent(tree, id) == nil
    end

    test "attributes keep source order" do
      {tree, id} = Tree.new() |> Tree.create("div", [{"id", "a"}, {"class", "b"}])

      assert Tree.attrs(tree, id) == [{"id", "a"}, {"class", "b"}]
      assert Tree.attr(tree, id, "class") == "b"
      assert Tree.attr(tree, id, "missing") == nil
      assert Tree.attr(tree, id, "missing", "") == ""
      assert Tree.first_attr(tree, id, ["class", "id"]) == "a"
    end

    test "put_attr replaces in place, keeping position" do
      tree =
        Tree.new()
        |> Tree.create("div", [{"id", "a"}, {"class", "b"}])
        |> then(fn {t, id} -> Tree.put_attr(t, id, "id", "z") end)

      [id] = Tree.all_ids(tree) |> Enum.filter(&(Tree.tag(tree, &1) == "div"))
      assert Tree.attrs(tree, id) == [{"id", "z"}, {"class", "b"}]
    end
  end

  describe "parse/1" do
    test "builds an lxml-style tree with text and tail" do
      tree = Tree.parse(~s|<html><body><p>Hello <b>world</b>!</p></body></html>|)

      [p] = Tree.find_all(tree, Tree.root(tree), "p")
      assert Tree.text(tree, p) == "Hello "

      [b] = Tree.children(tree, p)
      assert Tree.tag(tree, b) == "b"
      assert Tree.text(tree, b) == "world"
      assert Tree.tail(tree, b) == "!"
    end

    test "text_content concatenates text and tails in document order" do
      tree = Tree.parse(~s|<html><body><div>a<p>b</p>c<p>d</p>e</div></body></html>|)
      [div] = Tree.find_all(tree, Tree.root(tree), "div")

      assert Tree.text_content(tree, div) == "abcde"
      assert Tree.itertext(tree, div) == ["a", "b", "c", "d", "e"]
    end

    test "root is the html element" do
      tree = Tree.parse(~s|<html><body><p>x</p></body></html>|)
      assert Tree.tag(tree, Tree.root(tree)) == "html"
    end
  end

  describe "tree navigation" do
    setup do
      tree = Tree.parse(~s|<html><body><div><p>1</p><span>2</span><p>3</p></div></body></html>|)
      [div] = Tree.find_all(tree, Tree.root(tree), "div")
      {:ok, tree: tree, div: div}
    end

    test "iter yields self then descendants in document order", %{tree: tree, div: div} do
      assert Enum.map(Tree.iter(tree, div), &Tree.tag(tree, &1)) == ["div", "p", "span", "p"]
      assert Enum.map(Tree.iterdescendants(tree, div), &Tree.tag(tree, &1)) == ["p", "span", "p"]
    end

    test "iter can filter by tag", %{tree: tree, div: div} do
      assert length(Tree.iter(tree, div, ["p"])) == 2
    end

    test "siblings", %{tree: tree, div: div} do
      [p1, span, p3] = Tree.children(tree, div)

      assert Tree.next_sibling(tree, p1) == span
      assert Tree.prev_sibling(tree, span) == p1
      assert Tree.next_sibling(tree, p3) == nil
      assert Tree.prev_sibling(tree, p1) == nil
      assert Tree.index_in_parent(tree, span) == 1
    end

    test "ancestors", %{tree: tree, div: div} do
      [p1 | _] = Tree.children(tree, div)
      assert Enum.map(Tree.ancestors(tree, p1), &Tree.tag(tree, &1)) == ["div", "body", "html"]
    end
  end

  describe "mutation" do
    test "append moves an element, detaching it from its old parent" do
      tree = Tree.parse(~s|<html><body><div><p>1</p></div><section/></body></html>|)
      [div] = Tree.find_all(tree, Tree.root(tree), "div")
      [section] = Tree.find_all(tree, Tree.root(tree), "section")
      [p] = Tree.children(tree, div)

      tree = Tree.append(tree, section, p)

      assert Tree.children(tree, div) == []
      assert Tree.children(tree, section) == [p]
      assert Tree.parent(tree, p) == section
    end

    test "delete_element keeps the tail by default" do
      tree = Tree.parse(~s|<html><body><div>a<p>b</p>c</div></body></html>|)
      [div] = Tree.find_all(tree, Tree.root(tree), "div")
      [p] = Tree.children(tree, div)

      assert Tree.text_content(Tree.delete_element(tree, p), div) == "ac"
      assert Tree.text_content(Tree.delete_element(tree, p, keep_tail: false), div) == "a"
    end

    test "delete_element joins the tail onto the previous sibling" do
      tree = Tree.parse(~s|<html><body><div><i>x</i><p>b</p>c</div></body></html>|)
      [div] = Tree.find_all(tree, Tree.root(tree), "div")
      [i, p] = Tree.children(tree, div)

      tree = Tree.delete_element(tree, p)
      assert Tree.tail(tree, i) == "c"
    end

    test "strip_tags removes the element but keeps its content in place" do
      tree = Tree.parse(~s|<html><body><p>a<b>bold</b>c</p></body></html>|)
      [p] = Tree.find_all(tree, Tree.root(tree), "p")

      tree = Tree.strip_tags(tree, Tree.root(tree), ["b"])

      assert Tree.children(tree, p) == []
      assert Tree.text(tree, p) == "abold" <> "c"
    end

    test "strip_tags lifts children of the stripped element" do
      tree = Tree.parse(~s|<html><body><p>a<b>x<i>y</i>z</b>c</p></body></html>|)
      [p] = Tree.find_all(tree, Tree.root(tree), "p")

      tree = Tree.strip_tags(tree, Tree.root(tree), ["b"])

      assert Enum.map(Tree.children(tree, p), &Tree.tag(tree, &1)) == ["i"]
      assert Tree.text(tree, p) == "ax"
      [i] = Tree.children(tree, p)
      assert Tree.tail(tree, i) == "zc"
    end

    test "strip_elements removes the whole subtree but keeps the tail" do
      tree = Tree.parse(~s|<html><body><p>a<b>bold</b>c</p></body></html>|)
      [p] = Tree.find_all(tree, Tree.root(tree), "p")

      tree = Tree.strip_elements(tree, Tree.root(tree), ["b"])

      assert Tree.children(tree, p) == []
      assert Tree.text_content(tree, p) == "ac"
    end

    test "deep_copy produces an independent detached subtree" do
      tree = Tree.parse(~s|<html><body><div><p>1</p></div></body></html>|)
      [div] = Tree.find_all(tree, Tree.root(tree), "div")

      {tree, copy} = Tree.deep_copy(tree, div)
      assert Tree.parent(tree, copy) == nil
      assert Tree.text_content(tree, copy) == "1"

      [copy_p] = Tree.children(tree, copy)
      tree = Tree.put_text(tree, copy_p, "changed")

      assert Tree.text_content(tree, div) == "1"
      assert Tree.text_content(tree, copy) == "changed"
    end
  end

  describe "serialization" do
    test "to_html round-trips a simple document" do
      tree = Tree.parse(~s|<html><body><p class="x">hi<br/>there</p></body></html>|)
      [p] = Tree.find_all(tree, Tree.root(tree), "p")

      assert Tree.to_html(tree, p) == ~s|<p class="x">hi<br>there</p>|
    end

    test "to_html escapes text" do
      {tree, id} = Tree.new() |> Tree.create("p")
      tree = Tree.put_text(tree, id, "a < b & c")

      assert Tree.to_html(tree, id) == "<p>a &lt; b &amp; c</p>"
    end
  end
end
