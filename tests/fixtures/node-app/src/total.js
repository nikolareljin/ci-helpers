module.exports = function total(amounts) {
  return amounts.reduce((sum, amount) => sum + amount, 0);
};
