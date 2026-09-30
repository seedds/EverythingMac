mod common;
use common::*;
use everything_mac_syntax::*;

#[test]
fn block_06_filters_mix() {
    let s1 = parse_ok("folder:src ext:rs regex:.*\\.rs$");
    let p1 = as_and(&s1);
    assert!(p1.len() >= 3);
    let s2 = parse_ok("ext:rs folder:src dm:today");
    let p2 = as_and(&s2);
    let l2 = p2.len();
    filter_is_kind(&p2[l2 - 1], &FilterKind::DateModified);
    let s3 = parse_ok("dc:pastweek a b c");
    let p3 = as_and(&s3);
    let l3 = p3.len();
    filter_is_kind(&p3[l3 - 1], &FilterKind::DateCreated);
    let s4 = parse_ok("type:picture folder:assets a b");
    let p4 = as_and(&s4);
    assert!(p4.len() >= 3);
    let s5 = parse_ok("doc: a b c dm:today");
    let p5 = as_and(&s5);
    let l5 = p5.len();
    filter_is_kind(&p5[l5 - 1], &FilterKind::DateModified);
    let s6 = parse_ok("video: a b dc:pastweek");
    let p6 = as_and(&s6);
    let l6 = p6.len();
    filter_is_kind(&p6[l6 - 1], &FilterKind::DateCreated);
    let s7 = parse_ok("audio: ext:mp3 a b");
    let p7 = as_and(&s7);
    assert!(p7.len() >= 3);
    let s8 = parse_ok("folder:src !ext:md a");
    let p8 = as_and(&s8);
    assert!(p8.len() >= 2);
    let s9 = parse_ok("folder:src (!ext:md) a");
    let p9 = as_and(&s9);
    assert!(p9.len() >= 2);
    let s10 = parse_ok("(folder:src folder:components) ext:tsx");
    let p10 = as_and(&s10);
    assert!(p10.len() >= 2);
}

#[test]
fn filters_follow_words_in_typed_order() {
    let expr = parse_ok("alpha ext:first beta ext:second ext:txt folder:src");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 6);
    word_is(&parts[0], "alpha");
    word_is(&parts[1], "beta");
    filter_is_kind(&parts[2], &FilterKind::Ext);
    filter_is_kind(&parts[3], &FilterKind::Ext);
    filter_is_kind(&parts[4], &FilterKind::Ext);
    filter_is_kind(&parts[5], &FilterKind::Folder);
}

#[test]
fn ext_filter_only() {
    let expr = parse_ok("ext:important");
    let term = as_term(&expr);
    match term {
        Term::Filter(f) => assert!(matches!(f.kind, FilterKind::Ext)),
        _ => panic!("expected ext filter"),
    }
}

#[test]
fn ext_filter_with_single_word() {
    let expr = parse_ok("ext:project alpha");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 2);
    word_is(&parts[0], "alpha");
    filter_is_kind(&parts[1], &FilterKind::Ext);
}

#[test]
fn multiple_ext_filters_preserve_order() {
    let expr = parse_ok("ext:alpha ext:beta ext:gamma");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 3);
    filter_is_kind(&parts[0], &FilterKind::Ext);
    filter_is_kind(&parts[1], &FilterKind::Ext);
    filter_is_kind(&parts[2], &FilterKind::Ext);
}

#[test]
fn ext_filter_at_end_stays_last() {
    let expr = parse_ok("alpha beta ext:project");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 3);
    word_is(&parts[0], "alpha");
    word_is(&parts[1], "beta");
    filter_is_kind(&parts[2], &FilterKind::Ext);
}

#[test]
fn ext_filter_moves_to_tail_from_middle() {
    let expr = parse_ok("alpha ext:project beta");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 3);
    word_is(&parts[0], "alpha");
    word_is(&parts[1], "beta");
    filter_is_kind(&parts[2], &FilterKind::Ext);
}

#[test]
fn ext_and_other_filters_ordered_correctly() {
    let expr = parse_ok("ext:txt ext:important dm:today");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 3);
    filter_is_kind(&parts[0], &FilterKind::Ext);
    filter_is_kind(&parts[1], &FilterKind::Ext);
    filter_is_kind(&parts[2], &FilterKind::DateModified);
}

#[test]
fn ext_filter_with_size_and_type() {
    let expr = parse_ok("size:>1mb ext:archive type:file");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 3);
    filter_is_kind(&parts[0], &FilterKind::Size);
    filter_is_kind(&parts[1], &FilterKind::Ext);
    filter_is_kind(&parts[2], &FilterKind::Type);
}

#[test]
fn ext_filter_with_parent_and_infolder() {
    let expr = parse_ok("alpha parent:/tmp beta infolder:/home gamma ext:work delta");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 7);

    filter_is_kind(&parts[0], &FilterKind::Parent);
    filter_is_kind(&parts[1], &FilterKind::InFolder);

    word_is(&parts[2], "alpha");
    word_is(&parts[3], "beta");
    word_is(&parts[4], "gamma");
    word_is(&parts[5], "delta");
    filter_is_kind(&parts[6], &FilterKind::Ext);
}

#[test]
fn parent_filter_moves_to_front() {
    let expr = parse_ok("alpha parent:/tmp beta");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 3);

    filter_is_kind(&parts[0], &FilterKind::Parent);
    word_is(&parts[1], "alpha");
    word_is(&parts[2], "beta");
}

#[test]
fn infolder_filter_moves_to_front() {
    let expr = parse_ok("alpha infolder:/tmp beta");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 3);

    filter_is_kind(&parts[0], &FilterKind::InFolder);
    word_is(&parts[1], "alpha");
    word_is(&parts[2], "beta");
}

#[test]
fn scope_filters_preserve_relative_order() {
    let expr = parse_ok("ext:one alpha parent:/tmp beta infolder:/home gamma");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 6);

    filter_is_kind(&parts[0], &FilterKind::Parent);
    filter_is_kind(&parts[1], &FilterKind::InFolder);
    word_is(&parts[2], "alpha");
    word_is(&parts[3], "beta");
    word_is(&parts[4], "gamma");
    filter_is_kind(&parts[5], &FilterKind::Ext);
}

#[test]
fn ext_filters_with_words_and_phrases() {
    let expr = parse_ok("alpha ext:proj1 \"beta gamma\" ext:proj2 delta");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 5);
    word_is(&parts[0], "alpha");
    word_is(&parts[1], "\"beta gamma\"");
    word_is(&parts[2], "delta");
    filter_is_kind(&parts[3], &FilterKind::Ext);
    filter_is_kind(&parts[4], &FilterKind::Ext);
}

#[test]
fn ext_filter_with_regex() {
    let expr = parse_ok("regex:.*\\.txt$ ext:docs");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 2);
    regex_is(&parts[0], ".*\\.txt$");
    filter_is_kind(&parts[1], &FilterKind::Ext);
}

#[test]
fn ext_filter_in_not_expression() {
    let expr = parse_ok("alpha !ext:temporary");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 2);
    word_is(&parts[0], "alpha");
    let inner = as_not(&parts[1]);
    filter_is_kind(inner, &FilterKind::Ext);
}

#[test]
fn ext_filters_preserve_relative_order() {
    let expr = parse_ok("word1 ext:first word2 ext:second word3 ext:third");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 6);

    word_is(&parts[0], "word1");
    word_is(&parts[1], "word2");
    word_is(&parts[2], "word3");
    filter_is_kind(&parts[3], &FilterKind::Ext);
    filter_is_kind(&parts[4], &FilterKind::Ext);
    filter_is_kind(&parts[5], &FilterKind::Ext);
}

#[test]
fn ext_filter_with_nested_groups() {
    let expr = parse_ok("(ext:alpha beta) gamma");
    let parts = as_and(&expr);
    // Optimizer flattens nested AND groups, so (ext:alpha beta) gamma becomes ext:alpha beta gamma
    assert_eq!(parts.len(), 3);

    word_is(&parts[0], "beta");
    word_is(&parts[1], "gamma");
    filter_is_kind(&parts[2], &FilterKind::Ext);
}

#[test]
fn ext_filter_with_or_expression() {
    let expr = parse_ok("ext:alpha | ext:beta");
    let parts = as_or(&expr);
    assert_eq!(parts.len(), 2);

    filter_is_kind(&parts[0], &FilterKind::Ext);
    filter_is_kind(&parts[1], &FilterKind::Ext);
}

#[test]
fn ext_filter_complex_boolean() {
    let expr = parse_ok("(ext:important | ext:urgent) ext:txt");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 2);

    // First element is the OR group
    let or_parts = as_or(&parts[0]);
    assert_eq!(or_parts.len(), 2);
    filter_is_kind(&or_parts[0], &FilterKind::Ext);
    filter_is_kind(&or_parts[1], &FilterKind::Ext);

    // Second element is the ext filter
    filter_is_kind(&parts[1], &FilterKind::Ext);
}

#[test]
fn no_filters_stays_unchanged() {
    let expr = parse_ok("alpha beta gamma");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 3);
    word_is(&parts[0], "alpha");
    word_is(&parts[1], "beta");
    word_is(&parts[2], "gamma");
}

#[test]
fn only_non_ext_filters() {
    let expr = parse_ok("ext:txt dm:today size:>1kb");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 3);

    // All should be filters, order preserved
    filter_is_kind(&parts[0], &FilterKind::Ext);
    filter_is_kind(&parts[1], &FilterKind::DateModified);
    filter_is_kind(&parts[2], &FilterKind::Size);
}

#[test]
fn ext_filter_with_empty_query_parts() {
    let expr = parse_ok("  ext:alpha   beta  ");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 2);
    word_is(&parts[0], "beta");
    filter_is_kind(&parts[1], &FilterKind::Ext);
}

#[test]
fn ext_filter_with_wildcard() {
    let expr = parse_ok("*.txt ext:docs");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 2);
    word_is(&parts[0], "*.txt");
    filter_is_kind(&parts[1], &FilterKind::Ext);
}

// ============ Corner Cases ============

#[test]
fn multiple_priority_filters_with_duplicates() {
    let expr = parse_ok("ext:a parent:/tmp ext:b infolder:/home ext:c parent:/usr");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 6);

    filter_is_kind(&parts[0], &FilterKind::Parent);
    filter_is_kind(&parts[1], &FilterKind::InFolder);
    filter_is_kind(&parts[2], &FilterKind::Parent);
    filter_is_kind(&parts[3], &FilterKind::Ext);
    filter_is_kind(&parts[4], &FilterKind::Ext);
    filter_is_kind(&parts[5], &FilterKind::Ext);
}

#[test]
fn all_three_priority_levels_mixed() {
    let expr = parse_ok(
        "word1 ext:txt parent:/a ext:one dm:today infolder:/b word2 ext:two size:>1kb parent:/c",
    );
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 10);
    filter_is_kind(&parts[0], &FilterKind::Parent);
    filter_is_kind(&parts[1], &FilterKind::InFolder);
    filter_is_kind(&parts[2], &FilterKind::Parent);
    word_is(&parts[3], "word1");
    word_is(&parts[4], "word2");
    filter_is_kind(&parts[5], &FilterKind::Ext);
    filter_is_kind(&parts[6], &FilterKind::Ext);
    filter_is_kind(&parts[7], &FilterKind::DateModified);
    filter_is_kind(&parts[8], &FilterKind::Ext);
    filter_is_kind(&parts[9], &FilterKind::Size);
}

#[test]
fn only_ext_filters() {
    let expr = parse_ok("ext:a ext:b ext:c");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 3);
    filter_is_kind(&parts[0], &FilterKind::Ext);
    filter_is_kind(&parts[1], &FilterKind::Ext);
    filter_is_kind(&parts[2], &FilterKind::Ext);
}

#[test]
fn only_parent_and_infolder_filters() {
    let expr = parse_ok("parent:/a infolder:/b parent:/c infolder:/d");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 4);

    // Should preserve encounter order since they're equal priority
    filter_is_kind(&parts[0], &FilterKind::Parent);
    filter_is_kind(&parts[1], &FilterKind::InFolder);
    filter_is_kind(&parts[2], &FilterKind::Parent);
    filter_is_kind(&parts[3], &FilterKind::InFolder);
}

#[test]
fn ext_with_phrase_and_regex() {
    let expr = parse_ok("\"hello world\" ext:test regex:^foo.*bar$ ext:second");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 4);

    word_is(&parts[0], "\"hello world\"");
    regex_is(&parts[1], "^foo.*bar$");
    filter_is_kind(&parts[2], &FilterKind::Ext);
    filter_is_kind(&parts[3], &FilterKind::Ext);
}

#[test]
fn nested_not_with_priority_filters() {
    let expr = parse_ok("word !ext:temp !parent:/tmp");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 3);

    // word comes first (non-filter), then NOT expressions
    word_is(&parts[0], "word");

    // Both NOT expressions should be present (they are non-filters too)
    match &parts[1] {
        Expr::Not(_) => {}
        other => panic!("expected Not expression, got: {other:?}"),
    }
    match &parts[2] {
        Expr::Not(_) => {}
        other => panic!("expected Not expression, got: {other:?}"),
    }
}

#[test]
fn priority_filters_in_or_expression() {
    let expr = parse_ok("ext:a | parent:/tmp | infolder:/home");
    let parts = as_or(&expr);
    assert_eq!(parts.len(), 3);

    // OR doesn't reorder, each operand is independent
    filter_is_kind(&parts[0], &FilterKind::Ext);
    filter_is_kind(&parts[1], &FilterKind::Parent);
    filter_is_kind(&parts[2], &FilterKind::InFolder);
}

#[test]
fn priority_filters_in_nested_and_groups() {
    let expr = parse_ok("(ext:a word1) (parent:/tmp word2) ext:txt");
    let parts = as_and(&expr);
    // Optimizer flattens nested AND groups
    assert_eq!(parts.len(), 5);

    filter_is_kind(&parts[0], &FilterKind::Parent);
    word_is(&parts[1], "word1");
    word_is(&parts[2], "word2");
    filter_is_kind(&parts[3], &FilterKind::Ext);
    filter_is_kind(&parts[4], &FilterKind::Ext);
}

#[test]
fn single_priority_filter_with_many_tail_filters() {
    let expr = parse_ok("ext:rs size:>1kb dm:today dc:yesterday ext:one type:file");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 6);
    filter_is_kind(&parts[0], &FilterKind::Ext);
    filter_is_kind(&parts[1], &FilterKind::Size);
    filter_is_kind(&parts[2], &FilterKind::DateModified);
    filter_is_kind(&parts[3], &FilterKind::DateCreated);
    filter_is_kind(&parts[4], &FilterKind::Ext);
    filter_is_kind(&parts[5], &FilterKind::Type);
}

#[test]
fn empty_ext_argument() {
    let expr = parse_ok("ext: word");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 2);

    word_is(&parts[0], "word");
    filter_is_kind(&parts[1], &FilterKind::Ext);
}

#[test]
fn priority_filters_with_comparison_and_range() {
    let expr =
        parse_ok("parent:/tmp size:>1gb..10gb infolder:/home dm:2024/1/1-2024/12/31 ext:work");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 5);

    filter_is_kind(&parts[0], &FilterKind::Parent);
    filter_is_kind(&parts[1], &FilterKind::InFolder);
    filter_is_kind(&parts[2], &FilterKind::Size);
    filter_is_kind(&parts[3], &FilterKind::DateModified);
    filter_is_kind(&parts[4], &FilterKind::Ext);
}

#[test]
fn interleaved_priority_and_tail_filters() {
    let expr =
        parse_ok("ext:txt ext:a size:>1kb parent:/tmp dm:today infolder:/home type:file ext:b");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 8);
    filter_is_kind(&parts[0], &FilterKind::Parent);
    filter_is_kind(&parts[1], &FilterKind::InFolder);
    filter_is_kind(&parts[2], &FilterKind::Ext);
    filter_is_kind(&parts[3], &FilterKind::Ext);
    filter_is_kind(&parts[4], &FilterKind::Size);
    filter_is_kind(&parts[5], &FilterKind::DateModified);
    filter_is_kind(&parts[6], &FilterKind::Type);
    filter_is_kind(&parts[7], &FilterKind::Ext);
}

#[test]
fn quoted_priority_filter_arguments() {
    let expr = parse_ok(
        "parent:\"/Users/My Documents\" ext:\"Work Projects\" infolder:\"/home/user/files\"",
    );
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 3);

    filter_is_kind(&parts[0], &FilterKind::Parent);
    filter_is_kind(&parts[1], &FilterKind::InFolder);
    filter_is_kind(&parts[2], &FilterKind::Ext);
}

#[test]
fn priority_filters_with_wildcards_in_arguments() {
    let expr = parse_ok("ext:proj* parent:/tmp/* infolder:/home/user/*");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 3);

    filter_is_kind(&parts[0], &FilterKind::Parent);
    filter_is_kind(&parts[1], &FilterKind::InFolder);
    filter_is_kind(&parts[2], &FilterKind::Ext);
}

#[test]
fn mixed_or_and_and_with_priority_filters() {
    let expr = parse_ok("(ext:urgent | ext:important) word parent:/tmp ext:txt");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 4);

    // OR group is not a filter, comes after priority filters
    filter_is_kind(&parts[0], &FilterKind::Parent);
    let or_parts = as_or(&parts[1]);
    assert_eq!(or_parts.len(), 2);
    filter_is_kind(&or_parts[0], &FilterKind::Ext);
    filter_is_kind(&or_parts[1], &FilterKind::Ext);
    word_is(&parts[2], "word");
    filter_is_kind(&parts[3], &FilterKind::Ext);
}

#[test]
fn deeply_nested_groups_with_priority_filters() {
    let expr = parse_ok("((ext:a word1) word2) parent:/tmp");
    let parts = as_and(&expr);
    // Flattened: ext:a word1 word2 parent:/tmp
    assert_eq!(parts.len(), 4);

    filter_is_kind(&parts[0], &FilterKind::Parent);
    word_is(&parts[1], "word1");
    word_is(&parts[2], "word2");
    filter_is_kind(&parts[3], &FilterKind::Ext);
}

#[test]
fn priority_filter_at_every_position() {
    // Test ext at beginning, middle, end
    let expr1 = parse_ok("ext:start word1 word2");
    let p1 = as_and(&expr1);
    assert_eq!(p1.len(), 3);
    filter_is_kind(&p1[2], &FilterKind::Ext);

    let expr2 = parse_ok("word1 ext:middle word2");
    let p2 = as_and(&expr2);
    assert_eq!(p2.len(), 3);
    filter_is_kind(&p2[2], &FilterKind::Ext);

    let expr3 = parse_ok("word1 word2 ext:end");
    let p3 = as_and(&expr3);
    assert_eq!(p3.len(), 3);
    filter_is_kind(&p3[2], &FilterKind::Ext);
}

#[test]
fn priority_filters_only_no_other_terms() {
    let expr = parse_ok("ext:a ext:b parent:/tmp infolder:/home parent:/usr");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 5);

    filter_is_kind(&parts[0], &FilterKind::Parent);
    filter_is_kind(&parts[1], &FilterKind::InFolder);
    filter_is_kind(&parts[2], &FilterKind::Parent);
    filter_is_kind(&parts[3], &FilterKind::Ext);
    filter_is_kind(&parts[4], &FilterKind::Ext);
}

#[test]
fn single_word_with_all_filter_types() {
    let expr = parse_ok("word ext:a parent:/tmp infolder:/home ext:txt");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 5);

    filter_is_kind(&parts[0], &FilterKind::Parent);
    filter_is_kind(&parts[1], &FilterKind::InFolder);
    word_is(&parts[2], "word");
    filter_is_kind(&parts[3], &FilterKind::Ext);
    filter_is_kind(&parts[4], &FilterKind::Ext);
}

#[test]
fn alternating_priority_and_non_priority() {
    let expr =
        parse_ok("ext:a ext:rs parent:/tmp size:>1kb infolder:/home dm:today ext:b type:file");
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 8);
    filter_is_kind(&parts[0], &FilterKind::Parent);
    filter_is_kind(&parts[1], &FilterKind::InFolder);
    filter_is_kind(&parts[2], &FilterKind::Ext);
    filter_is_kind(&parts[3], &FilterKind::Ext);
    filter_is_kind(&parts[4], &FilterKind::Size);
    filter_is_kind(&parts[5], &FilterKind::DateModified);
    filter_is_kind(&parts[6], &FilterKind::Ext);
    filter_is_kind(&parts[7], &FilterKind::Type);
}

#[test]
fn every_supported_filter_orders_by_level() {
    let expr = parse_ok(
        "word1 ext:a file: folder: ext:txt type:doc audio: video: doc: exe: \
         size:>1kb dm:today dc:yesterday parent:/tmp infolder:/home nosubfolders:/data \
         ext:b parent:/usr word2",
    );
    let parts = as_and(&expr);
    assert_eq!(parts.len(), 19);

    // Scope filters first, in encounter order.
    filter_is_kind(&parts[0], &FilterKind::Parent);
    filter_is_kind(&parts[1], &FilterKind::InFolder);
    filter_is_kind(&parts[2], &FilterKind::Parent);
    // Then words.
    word_is(&parts[3], "word1");
    word_is(&parts[4], "word2");
    // Then every other filter, in encounter order.
    let rest: Vec<_> = parts[5..]
        .iter()
        .map(|part| filter_kind(part).0.clone())
        .collect();
    assert_eq!(
        rest,
        [
            FilterKind::Ext,
            FilterKind::File,
            FilterKind::Folder,
            FilterKind::Ext,
            FilterKind::Type,
            FilterKind::Audio,
            FilterKind::Video,
            FilterKind::Doc,
            FilterKind::Exe,
            FilterKind::Size,
            FilterKind::DateModified,
            FilterKind::DateCreated,
            FilterKind::NoSubfolders,
            FilterKind::Ext,
        ]
    );
}
