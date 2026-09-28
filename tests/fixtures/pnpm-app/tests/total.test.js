const t=require("node:test");const a=require("node:assert");const total=require("../src/total");
t.test("adds",()=>{a.equal(total([1,2,39]),42)});
