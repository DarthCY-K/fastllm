"""Run native packed INT8 tests against an actual CPU FastLLM build.
Usage: python run_tests.py SOURCE BUILD --fixtures REAL_ROW_FIXTURE_DIR [--model MODEL_DIR]
Build first: cmake -S SOURCE -B BUILD -DUSE_CUDA=OFF -DUSE_NUMAS=OFF -DPY_API=OFF
             cmake --build BUILD --target fastllm_tools -j4
The supplied fixture manifest is generated from real model rows, not mocked data.
"""
import argparse,json,pathlib,shlex,subprocess,sys
p=argparse.ArgumentParser();p.add_argument('source',type=pathlib.Path);p.add_argument('build',type=pathlib.Path);p.add_argument('--fixtures',type=pathlib.Path,required=True);p.add_argument('--model',type=pathlib.Path)
a=p.parse_args();root=a.source.resolve();build=a.build.resolve();tests=root/'test/packed_int8';work=build/'packed-int8-tests';work.mkdir(exist_ok=True)
flags=(build/'CMakeFiles/fastllm_tools.dir/flags.make').read_text()
includes=shlex.split(next(line.split(' = ',1)[1] for line in flags.splitlines() if line.startswith('CXX_INCLUDES =')))
lib=build/'tools/ftllm'
def run(args):
 print('+',shlex.join(map(str,args)),flush=True)
 subprocess.run(list(map(str,args)),check=True,timeout=120,cwd=work)
run([sys.executable,tests/'test_classifier.py',root])
for name in ['test_native','test_interleaved','test_repack','test_data','test_loader','test_hf','test_real_headers']:
 command=['g++','-std=c++17','-ffunction-sections','-fdata-sections',*includes,tests/(name+'.cpp'),'-Wl,--gc-sections','-L'+str(lib),'-lfastllm_tools','-Wl,-rpath,'+str(lib),'-o',work/name]
 run(command)
 if name in ['test_native','test_interleaved','test_repack','test_data']:run([work/name])
fixture=work/'fixtures';run([sys.executable,tests/'prepare_fixtures.py',a.fixtures,fixture])
for file in sorted(fixture.glob('*.safetensors')):run([work/'test_loader',file])
tiny=work/'tiny-hf';tiny.mkdir(exist_ok=True)
(tiny/'model.safetensors').write_bytes((fixture/'case01.safetensors').read_bytes())
(tiny/'config.json').write_text(json.dumps({'model_type':'llama','hidden_size':5120,'num_hidden_layers':1,'num_attention_heads':40,'vocab_size':1}))
(tiny/'tokenizer.json').write_text(json.dumps({'model':{'type':'BPE','vocab':{'x':0},'merges':[]},'added_tokens':[]}))
(tiny/'tokenizer_config.json').write_text('{}')
run([work/'test_hf',tiny])
if a.model:run([work/'test_real_headers',a.model])
print('ALL NATIVE PACKED INT8 CPU/LOADER TESTS PASSED',flush=True)
