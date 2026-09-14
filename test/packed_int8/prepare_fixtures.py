import json,pathlib,struct,sys
import numpy as np
source,target=map(pathlib.Path,sys.argv[1:]);target.mkdir(exist_ok=True,parents=True)
for i,case in enumerate(json.loads((source/'manifest.json').read_text())):
 z=np.load(case['file']);cols=case['columns']
 packed=z['packed'].astype('<i4').reshape(1,-1)
 scales=(z['scale'].astype('<f4').ravel().view('<u4')>>16).astype('<u2').reshape(1,-1)
 items=[('x.weight_packed','I32',packed),('x.weight_scale','BF16',scales),('x.weight_shape','I64',np.array([1,cols],dtype='<i8'))]
 header={};data=b''
 for name,dtype,a in items:
  raw=a.tobytes();header[name]={'dtype':dtype,'shape':list(a.shape),'data_offsets':[len(data),len(data)+len(raw)]};data+=raw
 h=json.dumps(header).encode();(target/f'case{i:02}.safetensors').write_bytes(struct.pack('<Q',len(h))+h+data)
print('Prepared 8 small genuine safetensors fixtures from actual model rows')
