//! Fuzzy *live session* search over name / host / user / host:port (the
//! Ctrl+K palette). Persistent BM25/semantic search lives in search.rs.

pub struct Candidate {
    pub id: i32,
    pub name: String,
    pub host: String,
    pub user: String,
    pub port: u16,
    pub last_activity_ms: u64,
}

/// Subsequence fuzzy score. `None` when the query is not a subsequence of
/// `text`. Both sides are compared case-insensitively (unicode lowercase).
/// Higher is better.
pub fn score(query: &str, text: &str) -> Option<i32> {
    let q: Vec<char> = query.to_lowercase().chars().collect();
    let t: Vec<char> = text.to_lowercase().chars().collect();
    if q.is_empty() {
        return Some(0);
    }
    if q.len() > t.len() {
        return None;
    }

    let is_sep = |c: char| !c.is_alphanumeric();
    let mut total = 0i32;
    let mut qi = 0usize;
    let mut prev_match: Option<usize> = None;

    for (ti, &tc) in t.iter().enumerate() {
        if qi < q.len() && tc == q[qi] {
            let mut s = 10;
            if ti == 0 {
                s += 20; // prefix bonus
            } else if is_sep(t[ti - 1]) {
                s += 12; // word-start bonus
            }
            if let Some(p) = prev_match {
                if p + 1 == ti {
                    s += 15; // contiguous bonus
                } else {
                    // gap penalty, mild
                    s -= ((ti - p - 1).min(10)) as i32;
                }
            }
            total += s;
            prev_match = Some(ti);
            qi += 1;
        }
    }

    if qi < q.len() {
        return None;
    }
    // Prefer shorter haystacks for equal quality matches.
    total -= (t.len() as i32 - q.len() as i32).min(30) / 3;
    // Exact match beats everything.
    if q == t {
        total += 100;
    }
    Some(total)
}

/// Bonus for a hit on the name: it is the primary field, so a word-start
/// match on a name outranks a prefix match on a host.
const NAME_BONUS: i32 = 15;

fn best_term_score(term: &str, c: &Candidate) -> Option<i32> {
    let host_port = format!("{}:{}", c.host, c.port);
    let user_host = format!("{}@{}", c.user, c.host);
    [
        score(term, &c.name).map(|s| s + NAME_BONUS),
        score(term, &c.host),
        score(term, &c.user),
        score(term, &host_port),
        score(term, &user_host),
    ]
    .into_iter()
    .flatten()
    .max()
}

/// Whitespace splits the query into terms; every term must match some field
/// and the scores add up, so `neon tr` finds `neon-tram-07`.
fn best_score(query: &str, c: &Candidate) -> Option<i32> {
    let mut total = 0;
    for term in query.split_whitespace() {
        total += best_term_score(term, c)?;
    }
    Some(total)
}

/// Returns ids ordered by descending score. Empty (or whitespace) query
/// returns all candidates ordered by last activity, most recent first.
/// A query with spaces is a list of terms that must all match.
pub fn search(query: &str, candidates: &[Candidate]) -> Vec<i32> {
    let query = query.trim();
    if query.is_empty() {
        let mut all: Vec<&Candidate> = candidates.iter().collect();
        all.sort_by(|a, b| {
            b.last_activity_ms
                .cmp(&a.last_activity_ms)
                .then(a.id.cmp(&b.id))
        });
        return all.into_iter().map(|c| c.id).collect();
    }
    let mut scored: Vec<(i32, u64, i32)> = candidates
        .iter()
        .filter_map(|c| best_score(query, c).map(|s| (s, c.last_activity_ms, c.id)))
        .collect();
    scored.sort_by(|a, b| b.0.cmp(&a.0).then(b.1.cmp(&a.1)).then(a.2.cmp(&b.2)));
    scored.into_iter().map(|(_, _, id)| id).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn c(id: i32, name: &str, host: &str, user: &str, act: u64) -> Candidate {
        Candidate {
            id,
            name: name.into(),
            host: host.into(),
            user: user.into(),
            port: 22,
            last_activity_ms: act,
        }
    }

    #[test]
    fn empty_query_orders_by_activity() {
        let cs = vec![
            c(0, "neon-tram-07", "a", "u", 10),
            c(1, "jade-junk-42", "b", "u", 30),
            c(2, "lucky-ferry-13", "c", "u", 20),
        ];
        assert_eq!(search("", &cs), vec![1, 2, 0]);
        assert_eq!(search("   ", &cs), vec![1, 2, 0]);
    }

    #[test]
    fn ranking_prefers_prefix_and_contiguous() {
        let cs = vec![
            c(0, "neon-tram-07", "box.example.com", "root", 0),
            c(1, "tram-jade-11", "10.0.0.5", "alice", 0),
            c(2, "misty-peak-02", "tramway.hk", "bob", 0),
            c(3, "golden-junk-09", "server", "carol", 0),
        ];
        let r = search("tram", &cs);
        assert_eq!(r.len(), 3);
        assert_eq!(r[0], 1, "prefix match on name wins: {:?}", r);
        assert!(!r.contains(&3));
    }

    #[test]
    fn name_hits_outrank_host_hits_and_terms_split_on_space() {
        let cs = vec![
            c(0, "neon-tram-07", "box.example.com", "root", 0),
            c(1, "tram-jade-11", "10.0.0.5", "alice", 0),
            c(2, "misty-peak-02", "tramway.hk", "bob", 0),
            c(3, "golden-junk-09", "server", "carol", 0),
        ];
        // name prefix > name word start > host prefix
        assert_eq!(search("tram", &cs), vec![1, 0, 2]);
        // a space separates terms instead of being matched literally
        assert_eq!(search("neon tr", &cs), vec![0]);
        assert_eq!(search("tram alice", &cs), vec![1]);
        assert_eq!(search("  neon   tram  ", &cs), vec![0]);
        // every term must match
        assert!(search("neon zzz", &cs).is_empty());
    }

    #[test]
    fn matches_host_user_and_port() {
        let cs = vec![
            c(0, "neon-tram-07", "dev.causeway.hk", "leejw", 0),
            c(1, "jade-junk-42", "10.0.0.5", "root", 0),
        ];
        assert_eq!(search("root", &cs), vec![1]);
        assert_eq!(search("causeway", &cs), vec![0]);
        assert_eq!(search("10.0.0.5:22", &cs), vec![1]);
        assert_eq!(search("leejw@dev", &cs), vec![0]);
        assert!(search("zzz", &cs).is_empty());
    }

    #[test]
    fn case_insensitive_and_unicode() {
        let cs = vec![
            c(0, "Příliš-Žluťoučký", "h", "u", 0),
            c(1, "안녕-tram", "h", "u", 0),
        ];
        assert_eq!(search("PŘÍLIŠ", &cs), vec![0]);
        assert_eq!(search("žlu", &cs), vec![0]);
        assert_eq!(search("안녕", &cs), vec![1]);
    }

    #[test]
    fn subsequence_scoring_shape() {
        assert!(score("nt", "neon-tram").is_some());
        assert!(score("nm", "neon-tram").is_some());
        assert!(score("tn", "neon-tram").is_none());
        assert!(score("xyz", "neon-tram").is_none());
        assert!(score("neon", "neon-tram").unwrap() > score("nt", "neon-tram").unwrap());
        assert!(score("tram", "tram").unwrap() > score("tram", "neon-tram").unwrap());
    }
}
