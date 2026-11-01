#!/usr/bin/env python3
"""Audit app-owned localization catalogs; user content/protocol identifiers stay verbatim."""
import json,re,subprocess,sys
from pathlib import Path
root=Path(__file__).resolve().parent.parent
languages=['en','zh-Hant','zh-Hans'];errors=[]
tables={l:json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(root/f'Resources/{l}.lproj/Localizable.strings')])) for l in languages}
format_spec=re.compile(r'%(?!%)(?:\d+\$)?[-+0 #]*\d*(?:\.\d+)?(?:ll|l|z)?[@diufegs]')
for language,table in tables.items():
 if set(table)!=set(tables['en']):errors.append(f'{language}: catalog keys differ')
 for key,value in table.items():
  if not value:errors.append(f'{language}: empty value for {key}')
  if sorted(format_spec.findall(value))!=sorted(format_spec.findall(key)) and not key.startswith(('option.','example.','provider.','providerHelp.','optionHelp.')):
   errors.append(f'{language}: format placeholders differ for {key}')
  if language=='en' and re.search('[\u3400-\u9fff]',value):errors.append(f'English value contains Chinese: {key}')
for path in (root/'Sources/CloudMount').glob('*.swift'):
 for match in re.finditer(r'"((?:[^"\\]|\\.)*)"',path.read_text()):
  value=match[1]
  if re.search('[\u3400-\u9fff]',value) and '\\(' not in value and value not in tables['en']:
   errors.append(f'{path.name}: missing static app string: {value}')
providers=json.loads((root/'Tests/CloudMountTests/Fixtures/providers.json').read_text())
options={o['Name'] for p in providers for o in p['Options']}
for name in options:
 if 'option.'+name not in tables['en']:errors.append('Missing protocol option label: '+name)
for provider in providers:
 for prefix in ['provider.','providerHelp.']:
  if prefix+provider['Prefix'] not in tables['en']:errors.append('Missing service translation: '+prefix+provider['Prefix'])
triple=re.compile(r'(?:\bT|MobileText\.text)\(\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"\s*,\s*"((?:[^"\\]|\\.)*)"',re.S)
mobile_triples=0
for folder in [root/'Mobile/App',root/'Mobile/Shared',root/'Mobile/ProviderUI',root/'Sources/CloudMountMobileCore']:
 for path in folder.glob('*.swift'):
  for match in triple.finditer(path.read_text()):
   mobile_triples+=1
   if any(not part.strip() for part in match.groups()):errors.append(f'{path.name}: empty translation in mobile text')
   if re.search('[\u3400-\u9fff]',match[3]):errors.append(f'{path.name}: Chinese literal in mobile English text: '+match[3])
for language in languages:
 info=root/f'Mobile/Resources/{language}.lproj/InfoPlist.strings'
 values=json.loads(subprocess.check_output(['plutil','-convert','json','-o','-',str(info)]))
 for key in ['Lock vault','Unlock vault','NSLocalNetworkUsageDescription']:
  if not values.get(key):errors.append(f'{language}: missing InfoPlist {key}')
if errors:
 print('\n'.join(errors));sys.exit(1)
print(json.dumps({'languages':languages,'mac_catalog_keys_per_language':len(tables['en']),'static_mac_strings':'covered','format_placeholders':'matched','mobile_system_prompt_translations':'present','protocol_option_names_covered':len(options),'storage_service_translations':len(providers),'mobile_translation_triples_checked':mobile_triples},indent=2))
