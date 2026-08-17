import {
  executeSlowAdd,
  executePreloadedFieldAndInvertedCompare,
  executeLinearizedStringFieldWrites,
  executeGeneralDynamicObjectGraph,
  executePowMetamethodGraph,
  executeRepeatedPowMetamethodGraph,
} from "./harness.mjs";

const slowAdd = await executeSlowAdd();
const preloadedFieldCompare = await executePreloadedFieldAndInvertedCompare();
const linearizedStringFields = await executeLinearizedStringFieldWrites();
const generalDynamicObject = await executeGeneralDynamicObjectGraph();
const powMetamethod = await executePowMetamethodGraph();
const repeatedPowMetamethod = await executeRepeatedPowMetamethodGraph();
console.log(
  `operators: slow add ${slowAdd.objectSize}, preloaded ${preloadedFieldCompare.objectSize}, ` +
    `linearized ${linearizedStringFields.objectSize}, dynamic object ${generalDynamicObject.objectSize}, ` +
    `pow ${powMetamethod.objectSize}, repeated pow ${repeatedPowMetamethod.objectSize}`,
);
