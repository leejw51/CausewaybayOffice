//! Memorable, Hong Kong flavoured session names: `<adjective>-<hk-noun>-<NN>`.

pub const ADJECTIVES: &[&str] = &[
    "neon", "jade", "lucky", "misty", "golden", "rusty", "tokio", "async", "pixel", "retro",
    "sunny", "rainy", "humid", "cozy", "brisk", "quiet", "loud", "swift", "lazy", "sharp", "fuzzy",
    "silky", "spicy", "salty", "sweet", "bitter", "smoky", "shiny", "dusty", "foggy", "amber",
    "coral", "ivory", "scarlet", "violet", "indigo", "crimson", "cobalt", "mint", "lime", "velvet",
    "chrome", "static", "vivid", "sleepy", "hungry", "witty", "brave", "nimble", "mellow",
];

pub const NOUNS: &[&str] = &[
    "tram",
    "junk",
    "ferry",
    "dimsum",
    "wanchai",
    "mongkok",
    "causeway",
    "peak",
    "taxi",
    "minibus",
    "milktea",
    "egg-tart",
    "wonton",
    "congee",
    "pineapple-bun",
    "cha-chaan-teng",
    "sampan",
    "pier",
    "typhoon",
    "harbour",
    "kowloon",
    "sheung-wan",
    "tsim-sha-tsui",
    "lantau",
    "lamma",
    "cheung-chau",
    "star-ferry",
    "octopus",
    "mtr",
    "escalator",
    "neon-sign",
    "bamboo",
    "mahjong",
    "dragon",
    "lion",
    "temple",
    "joss",
    "lantern",
    "noodle",
    "bbq-pork",
    "roast-goose",
    "fishball",
    "siu-mai",
    "har-gow",
    "bolo-bao",
    "yuenyeung",
    "skyline",
    "victoria",
    "aberdeen",
    "shatin",
    "tuen-mun",
];

/// Tiny deterministic xorshift64* generator.
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Self {
        // Zero state would get stuck; splitmix the seed first.
        let mut z = seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^= z >> 31;
        Rng(if z == 0 { 0xDEAD_BEEF_CAFE_F00D } else { z })
    }

    pub fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    pub fn below(&mut self, n: usize) -> usize {
        (self.next_u64() % n as u64) as usize
    }
}

fn compose(rng: &mut Rng) -> String {
    let adj = ADJECTIVES[rng.below(ADJECTIVES.len())];
    let noun = NOUNS[rng.below(NOUNS.len())];
    let nn = rng.below(100);
    format!("{}-{}-{:02}", adj, noun, nn)
}

/// Generate a name not present in `taken`. A seed of 0 derives one from the
/// clock so repeated calls do not collide.
pub fn generate(seed: u64, taken: &[String]) -> String {
    let seed = if seed == 0 {
        crate::session::now_ms() ^ 0xA5A5
    } else {
        seed
    };
    let mut rng = Rng::new(seed);
    let mut candidate = compose(&mut rng);
    let mut tries = 0;
    while taken.iter().any(|t| t == &candidate) && tries < 10_000 {
        candidate = compose(&mut rng);
        tries += 1;
    }
    candidate
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn word_lists_are_big_enough() {
        assert!(ADJECTIVES.len() >= 40);
        assert!(NOUNS.len() >= 40);
    }

    #[test]
    fn format_is_adjective_noun_nn() {
        for seed in 1..200u64 {
            let n = generate(seed, &[]);
            let parts: Vec<&str> = n.rsplitn(2, '-').collect();
            assert_eq!(parts.len(), 2, "{}", n);
            let nn = parts[0];
            assert_eq!(nn.len(), 2, "{}", n);
            assert!(nn.chars().all(|c| c.is_ascii_digit()), "{}", n);
            let rest = parts[1];
            let adj = ADJECTIVES
                .iter()
                .find(|a| rest.starts_with(&format!("{}-", a)));
            assert!(adj.is_some(), "{}", n);
            let noun = &rest[adj.unwrap().len() + 1..];
            assert!(NOUNS.contains(&noun), "{}", n);
            assert!(n.len() <= 32, "{}", n);
        }
    }

    #[test]
    fn deterministic_for_seed() {
        assert_eq!(generate(42, &[]), generate(42, &[]));
        assert_ne!(generate(42, &[]), generate(43, &[]));
    }

    #[test]
    fn unique_against_taken() {
        let first = generate(7, &[]);
        let second = generate(7, std::slice::from_ref(&first));
        assert_ne!(first, second);
        let mut taken = Vec::new();
        for i in 0..300u64 {
            let n = generate(i, &taken);
            assert!(!taken.contains(&n));
            taken.push(n);
        }
    }
}
