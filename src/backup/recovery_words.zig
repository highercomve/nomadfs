//! BIP-39 24-word recovery phrases for 256-bit backup keys.
//!
//! Converts 32 bytes of entropy into 24 English words carrying an 8-bit
//! SHA-256 checksum, and parses a 24-word phrase back into the 32-byte
//! entropy while tolerating case differences and extra whitespace.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

/// Entropy size in bytes (256 bits).
pub const entropy_len = 32;

/// Number of words in a 256-bit recovery phrase.
pub const word_count = 24;

/// Longest word in the English BIP-39 wordlist.
pub const max_word_len = 8;

/// Maximum length of a canonical space-separated 24-word phrase.
pub const max_phrase_len = word_count * max_word_len + (word_count - 1);

/// Maximum input length accepted by `decodePhrase` before rejecting.
pub const max_input_len = 4096;

pub const Error = error{
    InvalidWordCount,
    UnknownWord,
    ChecksumMismatch,
};

/// Encodes 256 bits of entropy into 24 11-bit wordlist indices (big-endian bit
/// order, with the high 8 bits of SHA-256(entropy) appended as checksum).
pub fn encodeIndices(entropy: [entropy_len]u8) [word_count]u11 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&entropy, &digest, .{});

    var bits: [entropy_len + 1]u8 = undefined;
    @memcpy(bits[0..entropy_len], &entropy);
    bits[entropy_len] = digest[0];
    defer std.crypto.secureZero(u8, &bits);

    var indices: [word_count]u11 = undefined;
    for (0..word_count) |word_i| {
        var idx: u11 = 0;
        const base_bit = word_i * 11;
        for (0..11) |b| {
            const bit_pos = base_bit + b;
            const byte_idx = bit_pos / 8;
            const shift: u3 = @intCast(7 - (bit_pos % 8));
            const bit: u11 = @intCast((bits[byte_idx] >> shift) & 1);
            idx = (idx << 1) | bit;
        }
        indices[word_i] = idx;
    }
    return indices;
}

/// Encodes 256 bits of entropy into 24 slices from `wordlist`.
pub fn encodeWords(entropy: [entropy_len]u8) [word_count][]const u8 {
    var indices = encodeIndices(entropy);
    defer std.crypto.secureZero(u11, &indices);

    var out: [word_count][]const u8 = undefined;
    for (indices, 0..) |idx, i| {
        out[i] = wordlist[idx];
    }
    return out;
}

/// Formats 256 bits of entropy as 24 space-separated words into `out` and
/// returns the written slice.
pub fn formatPhrase(entropy: [entropy_len]u8, out: *[max_phrase_len]u8) []const u8 {
    const words = encodeWords(entropy);
    var pos: usize = 0;
    for (words, 0..) |w, i| {
        if (i != 0) {
            out[pos] = ' ';
            pos += 1;
        }
        @memcpy(out[pos .. pos + w.len], w);
        pos += w.len;
    }
    return out[0..pos];
}

/// Allocates and returns a caller-owned canonical 24-word recovery phrase.
pub fn encodePhraseAlloc(allocator: std.mem.Allocator, entropy: [entropy_len]u8) std.mem.Allocator.Error![]u8 {
    var buf: [max_phrase_len]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    const phrase = formatPhrase(entropy, &buf);
    return allocator.dupe(u8, phrase);
}

/// Decodes 24 words back to 32 bytes of entropy, validating every word and the
/// 8-bit SHA-256 checksum. Each word is trimmed of ASCII whitespace and matched
/// case-insensitively.
pub fn decodeWords(words: []const []const u8) Error![entropy_len]u8 {
    if (words.len != word_count) return Error.InvalidWordCount;

    var indices: [word_count]u11 = undefined;
    defer std.crypto.secureZero(u11, &indices);

    for (words, 0..) |raw_word, i| {
        const trimmed = std.mem.trim(u8, raw_word, &std.ascii.whitespace);
        indices[i] = wordIndex(trimmed) orelse return Error.UnknownWord;
    }

    return decodeIndices(indices);
}

/// Decodes 24 11-bit wordlist indices into 32 bytes of entropy and verifies the
/// 8-bit SHA-256 checksum.
pub fn decodeIndices(indices: [word_count]u11) Error![entropy_len]u8 {
    var bits = [_]u8{0} ** (entropy_len + 1);
    defer std.crypto.secureZero(u8, &bits);

    for (indices, 0..) |idx, word_i| {
        const base_bit = word_i * 11;
        for (0..11) |b| {
            const shift: u4 = @intCast(10 - b);
            const bit: u8 = @intCast((idx >> shift) & 1);
            const bit_pos = base_bit + b;
            const byte_idx = bit_pos / 8;
            const byte_shift: u3 = @intCast(7 - (bit_pos % 8));
            bits[byte_idx] |= bit << byte_shift;
        }
    }

    const entropy = bits[0..entropy_len].*;
    const checksum = bits[entropy_len];

    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(&entropy, &digest, .{});
    if (checksum != digest[0]) return Error.ChecksumMismatch;

    return entropy;
}

/// Parses a whitespace-separated 24-word recovery phrase (case- and
/// whitespace-tolerant) into 32 bytes of entropy, verifying the BIP-39
/// checksum.
pub fn decodePhrase(phrase: []const u8) Error![entropy_len]u8 {
    if (phrase.len > max_input_len) return Error.InvalidWordCount;

    var words: [word_count][]const u8 = undefined;
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, phrase, &std.ascii.whitespace);
    while (it.next()) |token| {
        if (count >= word_count) return Error.InvalidWordCount;
        words[count] = token;
        count += 1;
    }
    if (count != word_count) return Error.InvalidWordCount;

    return decodeWords(&words);
}

/// Validates `phrase` (24 words and checksum) and writes the canonical
/// lowercase, single-space-separated representation into `out`.
pub fn canonicalizePhrase(phrase: []const u8, out: *[max_phrase_len]u8) Error![]const u8 {
    var entropy = try decodePhrase(phrase);
    defer std.crypto.secureZero(u8, &entropy);
    return formatPhrase(entropy, out);
}

/// Case-insensitive binary search of `word` in the sorted 2048-word English
/// BIP-39 wordlist.
pub fn wordIndex(word: []const u8) ?u11 {
    if (word.len == 0 or word.len > max_word_len) return null;

    var lower_buf: [max_word_len]u8 = undefined;
    for (word, 0..) |ch, i| {
        if (!std.ascii.isAlphabetic(ch)) return null;
        lower_buf[i] = std.ascii.toLower(ch);
    }
    const needle = lower_buf[0..word.len];

    var lo: usize = 0;
    var hi: usize = wordlist.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, needle, wordlist[mid])) {
            .eq => return @intCast(mid),
            .lt => hi = mid,
            .gt => lo = mid + 1,
        }
    }
    return null;
}

/// Official BIP-39 English wordlist (2048 words, alphabetically sorted).
pub const wordlist = [2048][]const u8{
    "abandon", "ability", "able", "about", "above", "absent", "absorb", "abstract",
    "absurd", "abuse", "access", "accident", "account", "accuse", "achieve", "acid",
    "acoustic", "acquire", "across", "act", "action", "actor", "actress", "actual",
    "adapt", "add", "addict", "address", "adjust", "admit", "adult", "advance",
    "advice", "aerobic", "affair", "afford", "afraid", "again", "age", "agent",
    "agree", "ahead", "aim", "air", "airport", "aisle", "alarm", "album",
    "alcohol", "alert", "alien", "all", "alley", "allow", "almost", "alone",
    "alpha", "already", "also", "alter", "always", "amateur", "amazing", "among",
    "amount", "amused", "analyst", "anchor", "ancient", "anger", "angle", "angry",
    "animal", "ankle", "announce", "annual", "another", "answer", "antenna", "antique",
    "anxiety", "any", "apart", "apology", "appear", "apple", "approve", "april",
    "arch", "arctic", "area", "arena", "argue", "arm", "armed", "armor",
    "army", "around", "arrange", "arrest", "arrive", "arrow", "art", "artefact",
    "artist", "artwork", "ask", "aspect", "assault", "asset", "assist", "assume",
    "asthma", "athlete", "atom", "attack", "attend", "attitude", "attract", "auction",
    "audit", "august", "aunt", "author", "auto", "autumn", "average", "avocado",
    "avoid", "awake", "aware", "away", "awesome", "awful", "awkward", "axis",
    "baby", "bachelor", "bacon", "badge", "bag", "balance", "balcony", "ball",
    "bamboo", "banana", "banner", "bar", "barely", "bargain", "barrel", "base",
    "basic", "basket", "battle", "beach", "bean", "beauty", "because", "become",
    "beef", "before", "begin", "behave", "behind", "believe", "below", "belt",
    "bench", "benefit", "best", "betray", "better", "between", "beyond", "bicycle",
    "bid", "bike", "bind", "biology", "bird", "birth", "bitter", "black",
    "blade", "blame", "blanket", "blast", "bleak", "bless", "blind", "blood",
    "blossom", "blouse", "blue", "blur", "blush", "board", "boat", "body",
    "boil", "bomb", "bone", "bonus", "book", "boost", "border", "boring",
    "borrow", "boss", "bottom", "bounce", "box", "boy", "bracket", "brain",
    "brand", "brass", "brave", "bread", "breeze", "brick", "bridge", "brief",
    "bright", "bring", "brisk", "broccoli", "broken", "bronze", "broom", "brother",
    "brown", "brush", "bubble", "buddy", "budget", "buffalo", "build", "bulb",
    "bulk", "bullet", "bundle", "bunker", "burden", "burger", "burst", "bus",
    "business", "busy", "butter", "buyer", "buzz", "cabbage", "cabin", "cable",
    "cactus", "cage", "cake", "call", "calm", "camera", "camp", "can",
    "canal", "cancel", "candy", "cannon", "canoe", "canvas", "canyon", "capable",
    "capital", "captain", "car", "carbon", "card", "cargo", "carpet", "carry",
    "cart", "case", "cash", "casino", "castle", "casual", "cat", "catalog",
    "catch", "category", "cattle", "caught", "cause", "caution", "cave", "ceiling",
    "celery", "cement", "census", "century", "cereal", "certain", "chair", "chalk",
    "champion", "change", "chaos", "chapter", "charge", "chase", "chat", "cheap",
    "check", "cheese", "chef", "cherry", "chest", "chicken", "chief", "child",
    "chimney", "choice", "choose", "chronic", "chuckle", "chunk", "churn", "cigar",
    "cinnamon", "circle", "citizen", "city", "civil", "claim", "clap", "clarify",
    "claw", "clay", "clean", "clerk", "clever", "click", "client", "cliff",
    "climb", "clinic", "clip", "clock", "clog", "close", "cloth", "cloud",
    "clown", "club", "clump", "cluster", "clutch", "coach", "coast", "coconut",
    "code", "coffee", "coil", "coin", "collect", "color", "column", "combine",
    "come", "comfort", "comic", "common", "company", "concert", "conduct", "confirm",
    "congress", "connect", "consider", "control", "convince", "cook", "cool", "copper",
    "copy", "coral", "core", "corn", "correct", "cost", "cotton", "couch",
    "country", "couple", "course", "cousin", "cover", "coyote", "crack", "cradle",
    "craft", "cram", "crane", "crash", "crater", "crawl", "crazy", "cream",
    "credit", "creek", "crew", "cricket", "crime", "crisp", "critic", "crop",
    "cross", "crouch", "crowd", "crucial", "cruel", "cruise", "crumble", "crunch",
    "crush", "cry", "crystal", "cube", "culture", "cup", "cupboard", "curious",
    "current", "curtain", "curve", "cushion", "custom", "cute", "cycle", "dad",
    "damage", "damp", "dance", "danger", "daring", "dash", "daughter", "dawn",
    "day", "deal", "debate", "debris", "decade", "december", "decide", "decline",
    "decorate", "decrease", "deer", "defense", "define", "defy", "degree", "delay",
    "deliver", "demand", "demise", "denial", "dentist", "deny", "depart", "depend",
    "deposit", "depth", "deputy", "derive", "describe", "desert", "design", "desk",
    "despair", "destroy", "detail", "detect", "develop", "device", "devote", "diagram",
    "dial", "diamond", "diary", "dice", "diesel", "diet", "differ", "digital",
    "dignity", "dilemma", "dinner", "dinosaur", "direct", "dirt", "disagree", "discover",
    "disease", "dish", "dismiss", "disorder", "display", "distance", "divert", "divide",
    "divorce", "dizzy", "doctor", "document", "dog", "doll", "dolphin", "domain",
    "donate", "donkey", "donor", "door", "dose", "double", "dove", "draft",
    "dragon", "drama", "drastic", "draw", "dream", "dress", "drift", "drill",
    "drink", "drip", "drive", "drop", "drum", "dry", "duck", "dumb",
    "dune", "during", "dust", "dutch", "duty", "dwarf", "dynamic", "eager",
    "eagle", "early", "earn", "earth", "easily", "east", "easy", "echo",
    "ecology", "economy", "edge", "edit", "educate", "effort", "egg", "eight",
    "either", "elbow", "elder", "electric", "elegant", "element", "elephant", "elevator",
    "elite", "else", "embark", "embody", "embrace", "emerge", "emotion", "employ",
    "empower", "empty", "enable", "enact", "end", "endless", "endorse", "enemy",
    "energy", "enforce", "engage", "engine", "enhance", "enjoy", "enlist", "enough",
    "enrich", "enroll", "ensure", "enter", "entire", "entry", "envelope", "episode",
    "equal", "equip", "era", "erase", "erode", "erosion", "error", "erupt",
    "escape", "essay", "essence", "estate", "eternal", "ethics", "evidence", "evil",
    "evoke", "evolve", "exact", "example", "excess", "exchange", "excite", "exclude",
    "excuse", "execute", "exercise", "exhaust", "exhibit", "exile", "exist", "exit",
    "exotic", "expand", "expect", "expire", "explain", "expose", "express", "extend",
    "extra", "eye", "eyebrow", "fabric", "face", "faculty", "fade", "faint",
    "faith", "fall", "false", "fame", "family", "famous", "fan", "fancy",
    "fantasy", "farm", "fashion", "fat", "fatal", "father", "fatigue", "fault",
    "favorite", "feature", "february", "federal", "fee", "feed", "feel", "female",
    "fence", "festival", "fetch", "fever", "few", "fiber", "fiction", "field",
    "figure", "file", "film", "filter", "final", "find", "fine", "finger",
    "finish", "fire", "firm", "first", "fiscal", "fish", "fit", "fitness",
    "fix", "flag", "flame", "flash", "flat", "flavor", "flee", "flight",
    "flip", "float", "flock", "floor", "flower", "fluid", "flush", "fly",
    "foam", "focus", "fog", "foil", "fold", "follow", "food", "foot",
    "force", "forest", "forget", "fork", "fortune", "forum", "forward", "fossil",
    "foster", "found", "fox", "fragile", "frame", "frequent", "fresh", "friend",
    "fringe", "frog", "front", "frost", "frown", "frozen", "fruit", "fuel",
    "fun", "funny", "furnace", "fury", "future", "gadget", "gain", "galaxy",
    "gallery", "game", "gap", "garage", "garbage", "garden", "garlic", "garment",
    "gas", "gasp", "gate", "gather", "gauge", "gaze", "general", "genius",
    "genre", "gentle", "genuine", "gesture", "ghost", "giant", "gift", "giggle",
    "ginger", "giraffe", "girl", "give", "glad", "glance", "glare", "glass",
    "glide", "glimpse", "globe", "gloom", "glory", "glove", "glow", "glue",
    "goat", "goddess", "gold", "good", "goose", "gorilla", "gospel", "gossip",
    "govern", "gown", "grab", "grace", "grain", "grant", "grape", "grass",
    "gravity", "great", "green", "grid", "grief", "grit", "grocery", "group",
    "grow", "grunt", "guard", "guess", "guide", "guilt", "guitar", "gun",
    "gym", "habit", "hair", "half", "hammer", "hamster", "hand", "happy",
    "harbor", "hard", "harsh", "harvest", "hat", "have", "hawk", "hazard",
    "head", "health", "heart", "heavy", "hedgehog", "height", "hello", "helmet",
    "help", "hen", "hero", "hidden", "high", "hill", "hint", "hip",
    "hire", "history", "hobby", "hockey", "hold", "hole", "holiday", "hollow",
    "home", "honey", "hood", "hope", "horn", "horror", "horse", "hospital",
    "host", "hotel", "hour", "hover", "hub", "huge", "human", "humble",
    "humor", "hundred", "hungry", "hunt", "hurdle", "hurry", "hurt", "husband",
    "hybrid", "ice", "icon", "idea", "identify", "idle", "ignore", "ill",
    "illegal", "illness", "image", "imitate", "immense", "immune", "impact", "impose",
    "improve", "impulse", "inch", "include", "income", "increase", "index", "indicate",
    "indoor", "industry", "infant", "inflict", "inform", "inhale", "inherit", "initial",
    "inject", "injury", "inmate", "inner", "innocent", "input", "inquiry", "insane",
    "insect", "inside", "inspire", "install", "intact", "interest", "into", "invest",
    "invite", "involve", "iron", "island", "isolate", "issue", "item", "ivory",
    "jacket", "jaguar", "jar", "jazz", "jealous", "jeans", "jelly", "jewel",
    "job", "join", "joke", "journey", "joy", "judge", "juice", "jump",
    "jungle", "junior", "junk", "just", "kangaroo", "keen", "keep", "ketchup",
    "key", "kick", "kid", "kidney", "kind", "kingdom", "kiss", "kit",
    "kitchen", "kite", "kitten", "kiwi", "knee", "knife", "knock", "know",
    "lab", "label", "labor", "ladder", "lady", "lake", "lamp", "language",
    "laptop", "large", "later", "latin", "laugh", "laundry", "lava", "law",
    "lawn", "lawsuit", "layer", "lazy", "leader", "leaf", "learn", "leave",
    "lecture", "left", "leg", "legal", "legend", "leisure", "lemon", "lend",
    "length", "lens", "leopard", "lesson", "letter", "level", "liar", "liberty",
    "library", "license", "life", "lift", "light", "like", "limb", "limit",
    "link", "lion", "liquid", "list", "little", "live", "lizard", "load",
    "loan", "lobster", "local", "lock", "logic", "lonely", "long", "loop",
    "lottery", "loud", "lounge", "love", "loyal", "lucky", "luggage", "lumber",
    "lunar", "lunch", "luxury", "lyrics", "machine", "mad", "magic", "magnet",
    "maid", "mail", "main", "major", "make", "mammal", "man", "manage",
    "mandate", "mango", "mansion", "manual", "maple", "marble", "march", "margin",
    "marine", "market", "marriage", "mask", "mass", "master", "match", "material",
    "math", "matrix", "matter", "maximum", "maze", "meadow", "mean", "measure",
    "meat", "mechanic", "medal", "media", "melody", "melt", "member", "memory",
    "mention", "menu", "mercy", "merge", "merit", "merry", "mesh", "message",
    "metal", "method", "middle", "midnight", "milk", "million", "mimic", "mind",
    "minimum", "minor", "minute", "miracle", "mirror", "misery", "miss", "mistake",
    "mix", "mixed", "mixture", "mobile", "model", "modify", "mom", "moment",
    "monitor", "monkey", "monster", "month", "moon", "moral", "more", "morning",
    "mosquito", "mother", "motion", "motor", "mountain", "mouse", "move", "movie",
    "much", "muffin", "mule", "multiply", "muscle", "museum", "mushroom", "music",
    "must", "mutual", "myself", "mystery", "myth", "naive", "name", "napkin",
    "narrow", "nasty", "nation", "nature", "near", "neck", "need", "negative",
    "neglect", "neither", "nephew", "nerve", "nest", "net", "network", "neutral",
    "never", "news", "next", "nice", "night", "noble", "noise", "nominee",
    "noodle", "normal", "north", "nose", "notable", "note", "nothing", "notice",
    "novel", "now", "nuclear", "number", "nurse", "nut", "oak", "obey",
    "object", "oblige", "obscure", "observe", "obtain", "obvious", "occur", "ocean",
    "october", "odor", "off", "offer", "office", "often", "oil", "okay",
    "old", "olive", "olympic", "omit", "once", "one", "onion", "online",
    "only", "open", "opera", "opinion", "oppose", "option", "orange", "orbit",
    "orchard", "order", "ordinary", "organ", "orient", "original", "orphan", "ostrich",
    "other", "outdoor", "outer", "output", "outside", "oval", "oven", "over",
    "own", "owner", "oxygen", "oyster", "ozone", "pact", "paddle", "page",
    "pair", "palace", "palm", "panda", "panel", "panic", "panther", "paper",
    "parade", "parent", "park", "parrot", "party", "pass", "patch", "path",
    "patient", "patrol", "pattern", "pause", "pave", "payment", "peace", "peanut",
    "pear", "peasant", "pelican", "pen", "penalty", "pencil", "people", "pepper",
    "perfect", "permit", "person", "pet", "phone", "photo", "phrase", "physical",
    "piano", "picnic", "picture", "piece", "pig", "pigeon", "pill", "pilot",
    "pink", "pioneer", "pipe", "pistol", "pitch", "pizza", "place", "planet",
    "plastic", "plate", "play", "please", "pledge", "pluck", "plug", "plunge",
    "poem", "poet", "point", "polar", "pole", "police", "pond", "pony",
    "pool", "popular", "portion", "position", "possible", "post", "potato", "pottery",
    "poverty", "powder", "power", "practice", "praise", "predict", "prefer", "prepare",
    "present", "pretty", "prevent", "price", "pride", "primary", "print", "priority",
    "prison", "private", "prize", "problem", "process", "produce", "profit", "program",
    "project", "promote", "proof", "property", "prosper", "protect", "proud", "provide",
    "public", "pudding", "pull", "pulp", "pulse", "pumpkin", "punch", "pupil",
    "puppy", "purchase", "purity", "purpose", "purse", "push", "put", "puzzle",
    "pyramid", "quality", "quantum", "quarter", "question", "quick", "quit", "quiz",
    "quote", "rabbit", "raccoon", "race", "rack", "radar", "radio", "rail",
    "rain", "raise", "rally", "ramp", "ranch", "random", "range", "rapid",
    "rare", "rate", "rather", "raven", "raw", "razor", "ready", "real",
    "reason", "rebel", "rebuild", "recall", "receive", "recipe", "record", "recycle",
    "reduce", "reflect", "reform", "refuse", "region", "regret", "regular", "reject",
    "relax", "release", "relief", "rely", "remain", "remember", "remind", "remove",
    "render", "renew", "rent", "reopen", "repair", "repeat", "replace", "report",
    "require", "rescue", "resemble", "resist", "resource", "response", "result", "retire",
    "retreat", "return", "reunion", "reveal", "review", "reward", "rhythm", "rib",
    "ribbon", "rice", "rich", "ride", "ridge", "rifle", "right", "rigid",
    "ring", "riot", "ripple", "risk", "ritual", "rival", "river", "road",
    "roast", "robot", "robust", "rocket", "romance", "roof", "rookie", "room",
    "rose", "rotate", "rough", "round", "route", "royal", "rubber", "rude",
    "rug", "rule", "run", "runway", "rural", "sad", "saddle", "sadness",
    "safe", "sail", "salad", "salmon", "salon", "salt", "salute", "same",
    "sample", "sand", "satisfy", "satoshi", "sauce", "sausage", "save", "say",
    "scale", "scan", "scare", "scatter", "scene", "scheme", "school", "science",
    "scissors", "scorpion", "scout", "scrap", "screen", "script", "scrub", "sea",
    "search", "season", "seat", "second", "secret", "section", "security", "seed",
    "seek", "segment", "select", "sell", "seminar", "senior", "sense", "sentence",
    "series", "service", "session", "settle", "setup", "seven", "shadow", "shaft",
    "shallow", "share", "shed", "shell", "sheriff", "shield", "shift", "shine",
    "ship", "shiver", "shock", "shoe", "shoot", "shop", "short", "shoulder",
    "shove", "shrimp", "shrug", "shuffle", "shy", "sibling", "sick", "side",
    "siege", "sight", "sign", "silent", "silk", "silly", "silver", "similar",
    "simple", "since", "sing", "siren", "sister", "situate", "six", "size",
    "skate", "sketch", "ski", "skill", "skin", "skirt", "skull", "slab",
    "slam", "sleep", "slender", "slice", "slide", "slight", "slim", "slogan",
    "slot", "slow", "slush", "small", "smart", "smile", "smoke", "smooth",
    "snack", "snake", "snap", "sniff", "snow", "soap", "soccer", "social",
    "sock", "soda", "soft", "solar", "soldier", "solid", "solution", "solve",
    "someone", "song", "soon", "sorry", "sort", "soul", "sound", "soup",
    "source", "south", "space", "spare", "spatial", "spawn", "speak", "special",
    "speed", "spell", "spend", "sphere", "spice", "spider", "spike", "spin",
    "spirit", "split", "spoil", "sponsor", "spoon", "sport", "spot", "spray",
    "spread", "spring", "spy", "square", "squeeze", "squirrel", "stable", "stadium",
    "staff", "stage", "stairs", "stamp", "stand", "start", "state", "stay",
    "steak", "steel", "stem", "step", "stereo", "stick", "still", "sting",
    "stock", "stomach", "stone", "stool", "story", "stove", "strategy", "street",
    "strike", "strong", "struggle", "student", "stuff", "stumble", "style", "subject",
    "submit", "subway", "success", "such", "sudden", "suffer", "sugar", "suggest",
    "suit", "summer", "sun", "sunny", "sunset", "super", "supply", "supreme",
    "sure", "surface", "surge", "surprise", "surround", "survey", "suspect", "sustain",
    "swallow", "swamp", "swap", "swarm", "swear", "sweet", "swift", "swim",
    "swing", "switch", "sword", "symbol", "symptom", "syrup", "system", "table",
    "tackle", "tag", "tail", "talent", "talk", "tank", "tape", "target",
    "task", "taste", "tattoo", "taxi", "teach", "team", "tell", "ten",
    "tenant", "tennis", "tent", "term", "test", "text", "thank", "that",
    "theme", "then", "theory", "there", "they", "thing", "this", "thought",
    "three", "thrive", "throw", "thumb", "thunder", "ticket", "tide", "tiger",
    "tilt", "timber", "time", "tiny", "tip", "tired", "tissue", "title",
    "toast", "tobacco", "today", "toddler", "toe", "together", "toilet", "token",
    "tomato", "tomorrow", "tone", "tongue", "tonight", "tool", "tooth", "top",
    "topic", "topple", "torch", "tornado", "tortoise", "toss", "total", "tourist",
    "toward", "tower", "town", "toy", "track", "trade", "traffic", "tragic",
    "train", "transfer", "trap", "trash", "travel", "tray", "treat", "tree",
    "trend", "trial", "tribe", "trick", "trigger", "trim", "trip", "trophy",
    "trouble", "truck", "true", "truly", "trumpet", "trust", "truth", "try",
    "tube", "tuition", "tumble", "tuna", "tunnel", "turkey", "turn", "turtle",
    "twelve", "twenty", "twice", "twin", "twist", "two", "type", "typical",
    "ugly", "umbrella", "unable", "unaware", "uncle", "uncover", "under", "undo",
    "unfair", "unfold", "unhappy", "uniform", "unique", "unit", "universe", "unknown",
    "unlock", "until", "unusual", "unveil", "update", "upgrade", "uphold", "upon",
    "upper", "upset", "urban", "urge", "usage", "use", "used", "useful",
    "useless", "usual", "utility", "vacant", "vacuum", "vague", "valid", "valley",
    "valve", "van", "vanish", "vapor", "various", "vast", "vault", "vehicle",
    "velvet", "vendor", "venture", "venue", "verb", "verify", "version", "very",
    "vessel", "veteran", "viable", "vibrant", "vicious", "victory", "video", "view",
    "village", "vintage", "violin", "virtual", "virus", "visa", "visit", "visual",
    "vital", "vivid", "vocal", "voice", "void", "volcano", "volume", "vote",
    "voyage", "wage", "wagon", "wait", "walk", "wall", "walnut", "want",
    "warfare", "warm", "warrior", "wash", "wasp", "waste", "water", "wave",
    "way", "wealth", "weapon", "wear", "weasel", "weather", "web", "wedding",
    "weekend", "weird", "welcome", "west", "wet", "whale", "what", "wheat",
    "wheel", "when", "where", "whip", "whisper", "wide", "width", "wife",
    "wild", "will", "win", "window", "wine", "wing", "wink", "winner",
    "winter", "wire", "wisdom", "wise", "wish", "witness", "wolf", "woman",
    "wonder", "wood", "wool", "word", "work", "world", "worry", "worth",
    "wrap", "wreck", "wrestle", "wrist", "write", "wrong", "yard", "year",
    "yellow", "you", "young", "youth", "zebra", "zero", "zone", "zoo",
};

test "recovery_words: wordlist integrity and ordering" {
    var h = Sha256.init(.{});
    for (wordlist, 0..) |word, i| {
        try std.testing.expect(word.len >= 3 and word.len <= max_word_len);
        if (i > 0) {
            try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, wordlist[i - 1], word));
        }
        try std.testing.expectEqual(@as(?u11, @intCast(i)), wordIndex(word));
        h.update(word);
        h.update("\n");
    }
    var digest: [Sha256.digest_length]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings(
        "2f5eed53a4727b4bf8880d8f3f199efc90e58503646d9ff8eff3a2ed3b24dbda",
        &hex,
    );
}

test "recovery_words: official BIP-39 256-bit test vectors" {
    const Vector = struct {
        entropy_hex: *const [64]u8,
        phrase: []const u8,
    };
    const vectors = [_]Vector{
        .{ .entropy_hex = "0000000000000000000000000000000000000000000000000000000000000000", .phrase = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art" },
        .{ .entropy_hex = "7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f", .phrase = "legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth useful legal winner thank year wave sausage worth title" },
        .{ .entropy_hex = "8080808080808080808080808080808080808080808080808080808080808080", .phrase = "letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic avoid letter advice cage absurd amount doctor acoustic bless" },
        .{ .entropy_hex = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", .phrase = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo vote" },
        .{ .entropy_hex = "68a79eaca2324873eacc50cb9c6eca8cc68ea5d936f98787c60c7ebc74e6ce7c", .phrase = "hamster diagram private dutch cause delay private meat slide toddler razor book happy fancy gospel tennis maple dilemma loan word shrug inflict delay length" },
        .{ .entropy_hex = "9f6a2878b2520799a44ef18bc7df394e7061a224d2c33cd015b157d746869863", .phrase = "panda eyebrow bullet gorilla call smoke muffin taste mesh discover soft ostrich alcohol speed nation flash devote level hobby quick inner drive ghost inside" },
        .{ .entropy_hex = "066dca1a2bb7e8a1db2832148ce9933eea0f3ac9548d793112d9a95c9407efad", .phrase = "all hour make first leader extend hole alien behind guard gospel lava path output census museum junior mass reopen famous sing advance salt reform" },
        .{ .entropy_hex = "f585c11aec520db57dd353c69554b21a89b20fb0650966fa0a9d6f74fd989d8f", .phrase = "void come effort suffer camp survey warrior heavy shoot primary clutch crush open amazing screen patrol group space point ten exist slush involve unfold" },
    };

    for (vectors) |vec| {
        var entropy: [entropy_len]u8 = undefined;
        _ = try std.fmt.hexToBytes(&entropy, vec.entropy_hex);

        var phrase_buf: [max_phrase_len]u8 = undefined;
        const encoded = formatPhrase(entropy, &phrase_buf);
        try std.testing.expectEqualStrings(vec.phrase, encoded);

        const alloc_phrase = try encodePhraseAlloc(std.testing.allocator, entropy);
        defer std.testing.allocator.free(alloc_phrase);
        try std.testing.expectEqualStrings(vec.phrase, alloc_phrase);

        const decoded = try decodePhrase(vec.phrase);
        try std.testing.expectEqualSlices(u8, &entropy, &decoded);
    }
}

test "recovery_words: case and whitespace tolerance" {
    const messy =
        "   ABANDON   Abandon\tabandon\r\n" ++
        "abandon   ABANDON abandon   abandon abandon\n" ++
        "  abandon abandon abandon abandon abandon abandon abandon abandon\t" ++
        "abandon abandon abandon abandon abandon abandon abandon   ART  \n";
    const decoded = try decodePhrase(messy);
    const expected = [_]u8{0} ** entropy_len;
    try std.testing.expectEqualSlices(u8, &expected, &decoded);

    var canonical_buf: [max_phrase_len]u8 = undefined;
    const canonical = try canonicalizePhrase(messy, &canonical_buf);
    try std.testing.expectEqualStrings(
        "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art",
        canonical,
    );
}

test "recovery_words: rejects typos, bad checksums, and wrong word counts" {
    // Valid words but bad checksum ("abandon" instead of "art" at the end).
    const bad_checksum = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon";
    try std.testing.expectError(Error.ChecksumMismatch, decodePhrase(bad_checksum));

    // Typo in a word ("aband0n" and "artt").
    const unknown_word = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon artt";
    try std.testing.expectError(Error.UnknownWord, decodePhrase(unknown_word));

    // Too few words (23).
    const too_few = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon";
    try std.testing.expectError(Error.InvalidWordCount, decodePhrase(too_few));

    // Too many words (25).
    const too_many = "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon art abandon";
    try std.testing.expectError(Error.InvalidWordCount, decodePhrase(too_many));

    // Empty input.
    try std.testing.expectError(Error.InvalidWordCount, decodePhrase("   \t\n  "));
}
