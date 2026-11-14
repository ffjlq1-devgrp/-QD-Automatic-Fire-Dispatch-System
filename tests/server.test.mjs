import test from 'node:test';
import assert from 'node:assert/strict';
import {selectStations,inventory,eq,eligible,compatible,withinPropagationRadius} from '../worker.js';
test('authentication comparison',()=>{assert.equal(eq('abc','abc'),true);assert.equal(eq('abc','abd'),false)});
test('inventory clamps invalid quantities',()=>{assert.equal(inventory({ENGINE:3,LADDER:-4}).ENGINE,3);assert.equal(inventory({ENGINE:3,LADDER:-4}).LADDER,0)});
test('nearest stations meet apparatus requirement',()=>{
 const a={id:'a',x:0,y:0,inventory:'{"ENGINE":1}',response_regions:'ALL'};
 const b={id:'b',x:100,y:0,inventory:'{"LADDER":1}',response_regions:'ALL'};
 const s=selectStations([a,b],{x:0,y:0},1,{ENGINE:1,LADDER:1});
 assert.deepEqual(s.selected.map(x=>x.id),['a','b']);assert.equal(s.missing.LADDER,0);
});
test('region coverage',()=>{assert.equal(eligible({response_regions:'ALL'},'A'),true);assert.equal(eligible({response_regions:'B,C'},'A'),false)});

test('building classification enforces appropriate dispatch types',()=>{
 assert.equal(compatible('RESIDENTIAL','COMMERCIAL_FIRE_ALARM'),false);
 assert.equal(compatible('COMMERCIAL','RESIDENTIAL_FIRE_ALARM'),false);
 for(const b of ['RESIDENTIAL','MULTI_RESIDENTIAL','COMMERCIAL','INDUSTRIAL','INSTITUTIONAL'])assert.equal(compatible(b,'AUTOMATIC_FIRE_ALARM'),true);
 assert.equal(compatible('WILDLAND','BRUSH_FIRE'),true);
 assert.equal(compatible('OUTDOOR','VEHICLE_FIRE'),true);
});
test('large fire propagation radius includes exactly 7 metres, excludes beyond and self',()=>{
 const origin={id:'a',x:100,y:100};
 assert.equal(withinPropagationRadius(origin,{id:'b',x:107,y:100}),true);
 assert.equal(withinPropagationRadius(origin,{id:'c',x:107.01,y:100}),false);
 assert.equal(withinPropagationRadius(origin,{id:'a',x:101,y:100}),false);
});
