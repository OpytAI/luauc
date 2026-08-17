import {
  executeTableInsertAppendPackageShape,
  executeDynamicArrayTablePackage,
  executeDynamicHashTablePackage,
  executeDynamicStringPackage,
  executeGenericTablePackage,
  executeMixedTablePackage,
  executeGlobalStatePackage,
} from "./harness.mjs";

const tableInsertAppend = await executeTableInsertAppendPackageShape();
const dynamicArrayTable = await executeDynamicArrayTablePackage();
const dynamicHashTable = await executeDynamicHashTablePackage();
const dynamicString = await executeDynamicStringPackage();
const genericTable = await executeGenericTablePackage();
const mixedTable = await executeMixedTablePackage();
const globalState = await executeGlobalStatePackage();
console.log(
  `tables: insert ${tableInsertAppend.objectSize}, array ${dynamicArrayTable.objectSize}, ` +
    `hash ${dynamicHashTable.objectSize}, string ${dynamicString.objectSize}, ` +
    `generic ${genericTable.objectSize}, mixed ${mixedTable.objectSize}, global ${globalState.objectSize}`,
);
