use everything_mac_syntax::*;

fn parse_filter(name: &str, arg: Option<&str>) -> Filter {
    let q = if let Some(a) = arg {
        format!("{name}:{a}")
    } else {
        format!("{name}:")
    };
    match parse_query(&q).unwrap().expr {
        Expr::Term(Term::Filter(f)) => f,
        other => panic!("expected filter, got {other:?}"),
    }
}

#[test]
fn maps_known_filter_names() {
    let cases: &[(&str, FilterKind)] = &[
        ("file", FilterKind::File),
        ("folder", FilterKind::Folder),
        ("ext", FilterKind::Ext),
        ("type", FilterKind::Type),
        ("audio", FilterKind::Audio),
        ("video", FilterKind::Video),
        ("doc", FilterKind::Doc),
        ("exe", FilterKind::Exe),
        ("size", FilterKind::Size),
        ("dm", FilterKind::DateModified),
        ("datemodified", FilterKind::DateModified),
        ("dc", FilterKind::DateCreated),
        ("datecreated", FilterKind::DateCreated),
        ("parent", FilterKind::Parent),
        ("infolder", FilterKind::InFolder),
        ("in", FilterKind::InFolder),
        ("nosubfolders", FilterKind::NoSubfolders),
    ];

    for (name, expected) in cases {
        let f = parse_filter(name, None);
        assert_eq!(&f.kind, expected, "name={name}");
        assert!(f.argument.is_none());
    }
}

/// Everything filters that EverythingMac does not implement, and any other
/// `name:` text, are ordinary words matched against names.
#[test]
fn unsupported_filter_names_are_words() {
    let names = [
        "content",
        "tag",
        "t",
        "da",
        "dateaccessed",
        "dr",
        "daterun",
        "child",
        "attrib",
        "attribdupe",
        "dmdupe",
        "dupe",
        "namepartdupe",
        "sizedupe",
        "artist",
        "album",
        "title",
        "genre",
        "year",
        "track",
        "comment",
        "width",
        "height",
        "dimensions",
        "orientation",
        "bitdepth",
        "case",
        "nowholefilename",
        "proj",
        "D",
    ];
    for name in names {
        for query in [format!("{name}:"), format!("{name}:value")] {
            assert_eq!(
                parse_query(&query).unwrap().expr,
                Expr::Term(Term::Word(query.clone())),
                "query={query}"
            );
        }
    }
}

#[test]
fn argument_shapes_overview() {
    // list
    let f = parse_filter("ext", Some("jpg;png;gif"));
    assert!(matches!(f.argument.unwrap().kind, ArgumentKind::List(_)));

    // range dotted
    let f = parse_filter("size", Some("1..10"));
    assert!(matches!(f.argument.unwrap().kind, ArgumentKind::Range(_)));

    // comparison
    let f = parse_filter("size", Some(">=100"));
    assert!(matches!(
        f.argument.unwrap().kind,
        ArgumentKind::Comparison(_)
    ));

    // phrase
    let f = parse_filter("parent", Some("\"/Users/demo\""));
    assert!(matches!(f.argument.unwrap().kind, ArgumentKind::Phrase));

    // bare
    let f = parse_filter("dm", Some("today"));
    assert!(matches!(f.argument.unwrap().kind, ArgumentKind::Bare));
}
