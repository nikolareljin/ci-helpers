//! Small enough to read in one screen, with something to test and nothing for
//! clippy to complain about -- so a leg that goes red means the preset did.

/// Sums the amounts.
pub fn total(amounts: &[i64]) -> i64 {
    amounts.iter().sum()
}

#[cfg(test)]
mod tests {
    use super::total;

    #[test]
    fn adds_the_amounts() {
        assert_eq!(total(&[1, 2, 39]), 42);
    }

    #[test]
    fn an_empty_basket_is_zero() {
        assert_eq!(total(&[]), 0);
    }
}
