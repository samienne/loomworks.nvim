-- loomworks.description — the pure description helpers (spec §1.10, §17.11):
-- normalisation, writer validation, git-style summary/body, display-width
-- truncation, inert rendering, statusline escaping, comment stripping.

local d = require("loomworks.description")

describe("description.normalize", function()
  it("returns nil for non-strings", function()
    assert.is_nil(d.normalize(nil))
    assert.is_nil(d.normalize(42))
    assert.is_nil(d.normalize({ "x" }))
    assert.is_nil(d.normalize(true))
  end)

  it("maps empty and whitespace-only text to nil", function()
    assert.is_nil(d.normalize(""))
    assert.is_nil(d.normalize("   "))
    assert.is_nil(d.normalize("\n\n  \r\n\t\n"))
  end)

  it("turns CRLF and lone CR into LF", function()
    assert.equals("a\nb\nc", d.normalize("a\r\nb\rc"))
  end)

  it("strips trailing whitespace per line, keeps leading indentation", function()
    assert.equals("a\n  b", d.normalize("a  \t\n  b   "))
  end)

  it("strips leading and trailing blank lines, keeps inner blank lines", function()
    assert.equals("sum\n\nbody", d.normalize("\n\n  \nsum\n\nbody\n\n \n"))
  end)

  it("is idempotent", function()
    local once = d.normalize("  x \r\n\r\n y  \n")
    assert.equals(once, d.normalize(once))
  end)
end)

describe("description.validate", function()
  it("accepts nil, plain text, LF and TAB", function()
    assert.is_true((d.validate(nil)))
    assert.is_true((d.validate("summary\n\n\tbody")))
    assert.is_true((d.validate("unicode — ünïcödé 漢字")))
  end)

  it("refuses C0 controls other than LF/TAB, DEL and C1 controls", function()
    for _, s in ipairs({ "a\27[31mb", "a\0b", "a\rb", "a\127b", "a\194\133b" }) do
      local ok, err = d.validate(s)
      assert.is_false(ok)
      assert.is_truthy(err:find("control character", 1, true))
    end
  end)

  it("refuses more than 4096 bytes", function()
    assert.is_true((d.validate(string.rep("x", 4096))))
    local ok, err = d.validate(string.rep("x", 4097))
    assert.is_false(ok)
    assert.is_truthy(err:find("too long", 1, true))
  end)

  it("prepare normalises then validates", function()
    local ok, s = d.prepare("  hi  \r\n")
    assert.is_true(ok)
    assert.equals("  hi", s)
    ok, s = d.prepare("   ")
    assert.is_true(ok)
    assert.is_nil(s)
    local err
    ok, s, err = d.prepare("x\27y")
    assert.is_false(ok)
    assert.is_truthy(err)
    ok, s, err = d.prepare(12)
    assert.is_false(ok)
    assert.is_truthy(err)
  end)
end)

describe("description.from_file", function()
  it("normalises strings and reports non-strings as invalid", function()
    assert.same({ "x" }, { d.from_file("x \n") })
    local desc, invalid = d.from_file(12)
    assert.is_nil(desc)
    assert.equals(12, invalid)
    desc, invalid = d.from_file(vim.NIL)
    assert.is_nil(desc)
    assert.is_nil(invalid)
    desc, invalid = d.from_file(nil)
    assert.is_nil(desc)
    assert.is_nil(invalid)
  end)
end)

describe("description.summary / body", function()
  it("splits git-style", function()
    local s = "Summary line\n\n\nFirst body line\n\nSecond paragraph"
    assert.equals("Summary line", d.summary(s))
    assert.equals("First body line\n\nSecond paragraph", d.body(s))
  end)

  it("has no body for a one-line description", function()
    assert.equals("only", d.summary("only"))
    assert.is_nil(d.body("only"))
  end)

  it("has no body when only blank lines follow", function()
    assert.is_nil(d.body("sum\n\n  \n"))
  end)

  it("nil for an absent description", function()
    assert.is_nil(d.summary(nil))
    assert.is_nil(d.body(nil))
  end)
end)

describe("description.fit", function()
  it("returns the text unchanged when it fits", function()
    assert.equals("hello", d.fit("hello", 5))
    assert.equals("hello", d.fit("hello", 10))
  end)

  it("truncates with an ellipsis within the column budget", function()
    assert.equals("hel…", d.fit("hello", 4))
    assert.equals(4, d.width(d.fit("hello", 4)))
    assert.equals("…", d.fit("hello", 1))
  end)

  it("returns empty for cols < 1 or nil text", function()
    assert.equals("", d.fit("hello", 0))
    assert.equals("", d.fit("hello", -3))
    assert.equals("", d.fit(nil, 10))
  end)

  it("never cuts inside a multi-byte character", function()
    local s = "ääääää"
    local r = d.fit(s, 4)
    assert.equals("äää…", r)
    -- The result is valid UTF-8 of the right width.
    assert.equals(4, d.width(r))
  end)

  it("counts East Asian wide characters as two columns", function()
    assert.equals(6, d.width("漢字漢"))
    local r = d.fit("漢字漢字", 5)
    assert.equals("漢字…", r)
    assert.is_true(d.width(r) <= 5)
    -- An odd budget never overshoots with a wide character.
    assert.equals("漢…", d.fit("漢字漢字", 4))
  end)

  it("treats combining marks as zero width", function()
    assert.equals(1, d.width("e\204\129")) -- e + U+0301
  end)
end)

describe("description.inert / inert_line", function()
  it("renders C0 controls in caret notation and DEL as ^?", function()
    assert.equals("a^[[31mb^?", d.inert("a\27[31mb\127"))
    assert.equals("^@^M", d.inert("\0\r"))
  end)

  it("renders C1 controls and bidi controls as \\u text", function()
    assert.equals("x\\u0085y", d.inert("x\194\133y"))
    assert.equals("a\\u202Eb", d.inert("a\226\128\174b"))
    assert.equals("a\\u2066b\\u2069", d.inert("a\226\129\166b\226\129\169"))
    assert.equals("a\\u202Ab", d.inert("a\226\128\170b"))
  end)

  it("keeps ordinary UTF-8 intact (including other U+20xx punctuation)", function()
    assert.equals("— ünï 漢 …", d.inert("— ünï 漢 …"))
  end)

  it("turns TAB into a space; inert keeps LF, inert_line flattens it", function()
    assert.equals("a b\nc", d.inert("a\tb\nc"))
    assert.equals("a b c", d.inert_line("a\tb\nc"))
    assert.is_nil(d.inert_line("x\ny\nz"):find("\n", 1, true))
  end)

  it("handles nil", function()
    assert.equals("", d.inert(nil))
    assert.equals("", d.inert_line(nil))
  end)
end)

describe("description.statusline_escape", function()
  it("doubles % so no statusline item can be injected", function()
    assert.equals("100%% %%{expr} %%#Hl#", d.statusline_escape("100% %{expr} %#Hl#"))
  end)

  it("drops control characters and bidi controls, spaces TAB/LF", function()
    assert.equals("a b c", d.statusline_escape("a\tb\nc"))
    assert.equals("ab", d.statusline_escape("a\27b"))
    assert.equals("ab", d.statusline_escape("a\194\133b"))
    assert.equals("ab", d.statusline_escape("a\226\128\174b"))
  end)

  it("handles nil", function()
    assert.equals("", d.statusline_escape(nil))
  end)
end)

describe("description.strip_comments", function()
  it("drops # lines and joins the rest", function()
    local lines = { "Summary", "", "# help line", "body", "#another" }
    assert.equals("Summary\n\nbody", d.strip_comments(lines))
  end)

  it("keeps an indented # (only a leading # is a comment)", function()
    assert.equals(" # not a comment", d.strip_comments({ " # not a comment" }))
  end)

  it("an all-comment buffer yields empty text (which normalises to nil)", function()
    local s = d.strip_comments({ "# a", "# b" })
    assert.equals("", s)
    assert.is_nil(d.normalize(s))
  end)
end)
