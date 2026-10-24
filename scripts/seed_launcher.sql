.bail on
BEGIN IMMEDIATE;
DROP TRIGGER IF EXISTS naturalbase_rdb_gridlayout_info_ON_INSERT;
DROP TRIGGER IF EXISTS naturalbase_rdb_gridlayout_info_ON_UPDATE;
DROP TRIGGER IF EXISTS naturalbase_rdb_gridlayout_info_ON_DELETE;
DELETE FROM gridlayout_info;
INSERT INTO gridlayout_info (user_id,info_id,info_name,file_type,container,type_id,width,height,page_index,column,row,appIcon_id,appLabel_id,app_status,app_index,bundle_name,module_name,ability_name,portrait_page_index,portrait_column,portrait_row,landscape_page_index,landscape_column,landscape_row,portrait_width,portrait_height,landscape_width,landscape_height,screen_id) VALUES
(100,'com.huawei.hmos.settingscom.huawei.hmos.settings.MainAbilityphone_settings0','设置',0,-100,0,1,1,0,0,0,0,0,0,0,'com.huawei.hmos.settings','phone_settings','com.huawei.hmos.settings.MainAbility',0,0,0,0,0,0,1,1,1,1,0),
(100,'com.huawei.hmos.photoscom.huawei.hmos.photos.MainAbilityphone_photos0','图库',0,-100,0,1,1,0,1,0,0,0,0,0,'com.huawei.hmos.photos','phone_photos','com.huawei.hmos.photos.MainAbility',0,1,0,0,1,0,1,1,1,1,0),
(100,'com.huawei.hmos.calculatorCalculatorAbilityphone0','计算器',0,-100,0,1,1,0,2,0,0,0,0,0,'com.huawei.hmos.calculator','phone','CalculatorAbility',0,2,0,0,2,0,1,1,1,1,0),
(100,'com.huawei.hmos.calendarMainAbilityphone0','日历',0,-100,0,1,1,0,3,0,0,0,0,0,'com.huawei.hmos.calendar','phone','MainAbility',0,3,0,0,3,0,1,1,1,1,0),
(100,'com.huawei.hmos.clockcom.huawei.hmos.clock.phoneentry0','时钟',0,-100,0,1,1,0,0,1,0,0,0,0,'com.huawei.hmos.clock','entry','com.huawei.hmos.clock.phone',0,0,1,0,0,1,1,1,1,1,0),
(100,'com.huawei.hmos.filesEntryAbilityentry0','文件管理',0,-100,0,1,1,0,1,1,0,0,0,0,'com.huawei.hmos.files','entry','EntryAbility',0,1,1,0,1,1,1,1,1,1,0),
(100,'com.huawei.hmos.notepadMainAbilityNotepadPhone0','备忘录',0,-100,0,1,1,0,2,1,0,0,0,0,'com.huawei.hmos.notepad','NotepadPhone','MainAbility',0,2,1,0,2,1,1,1,1,1,0),
(100,'com.huawei.hmsapp.appgalleryMainAbilityentry0','应用市场',0,-100,0,1,1,0,3,1,0,0,0,0,'com.huawei.hmsapp.appgallery','entry','MainAbility',0,3,1,0,3,1,1,1,1,1,0),
(100,'com.huawei.hmsapp.thememanagerMainAbilityentry0','主题',0,-100,0,1,1,1,0,0,0,0,0,0,'com.huawei.hmsapp.thememanager','entry','MainAbility',1,0,0,1,0,0,1,1,1,1,0),
(100,'com.huawei.hmsapp.musicMainAbilityphone0','音乐',0,-100,0,1,1,1,1,0,0,0,0,0,'com.huawei.hmsapp.music','phone','MainAbility',1,1,0,1,1,0,1,1,1,1,0),
(100,'com.huawei.hmsapp.himovieMainAbilityentry0','华为视频',0,-100,0,1,1,1,2,0,0,0,0,0,'com.huawei.hmsapp.himovie','entry','MainAbility',1,2,0,1,2,0,1,1,1,1,0),
(100,'com.ohos.contactscom.ohos.contacts.MainAbilityentry0','联系人',0,-101,0,1,1,-1,0,0,0,0,0,0,'com.ohos.contacts','entry','com.ohos.contacts.MainAbility',-1,0,0,-1,0,0,1,1,1,1,0),
(100,'com.ohos.mmscom.ohos.mms.MainAbilityentry0','信息',0,-101,0,1,1,-1,1,0,0,0,0,0,'com.ohos.mms','entry','com.ohos.mms.MainAbility',-1,1,0,-1,1,0,1,1,1,1,0),
(100,'com.huawei.hmos.browserMainAbilityentry0','浏览器',0,-101,0,1,1,-1,2,0,0,0,0,0,'com.huawei.hmos.browser','entry','MainAbility',-1,2,0,-1,2,0,1,1,1,1,0),
(100,'com.huawei.hmos.cameracom.huawei.hmos.camera.MainAbilityphone0','相机',0,-101,0,1,1,-1,3,0,0,0,0,0,'com.huawei.hmos.camera','phone','com.huawei.hmos.camera.MainAbility',-1,3,0,-1,3,0,1,1,1,1,0);
UPDATE gridlayout_info SET appIcon_id=50331649,appLabel_id=50331648 WHERE bundle_name='com.huawei.hmos.settings';
UPDATE gridlayout_info SET appIcon_id=352321538,appLabel_id=352321536 WHERE bundle_name='com.huawei.hmos.photos';
UPDATE gridlayout_info SET appIcon_id=67108867,appLabel_id=67108864 WHERE bundle_name='com.huawei.hmos.calculator';
UPDATE gridlayout_info SET appIcon_id=385876477,appLabel_id=385876071 WHERE bundle_name='com.huawei.hmos.calendar';
UPDATE gridlayout_info SET appIcon_id=50331649,appLabel_id=50331648 WHERE bundle_name='com.huawei.hmos.clock';
UPDATE gridlayout_info SET appIcon_id=16777217,appLabel_id=16777216 WHERE bundle_name='com.huawei.hmos.files';
UPDATE gridlayout_info SET appIcon_id=184550168,appLabel_id=184549402 WHERE bundle_name='com.huawei.hmos.notepad';
UPDATE gridlayout_info SET appIcon_id=67108882,appLabel_id=67108870 WHERE bundle_name='com.huawei.hmsapp.appgallery';
UPDATE gridlayout_info SET appIcon_id=16777217,appLabel_id=16777216 WHERE bundle_name='com.huawei.hmsapp.thememanager';
UPDATE gridlayout_info SET appIcon_id=1610612737,appLabel_id=1610612736 WHERE bundle_name='com.huawei.hmsapp.music';
UPDATE gridlayout_info SET appIcon_id=16777218,appLabel_id=16777217 WHERE bundle_name='com.huawei.hmsapp.himovie';
UPDATE gridlayout_info SET appIcon_id=100663299,appLabel_id=100663296 WHERE bundle_name='com.ohos.contacts';
UPDATE gridlayout_info SET appIcon_id=16777218,appLabel_id=16777216 WHERE bundle_name='com.ohos.mms';
UPDATE gridlayout_info SET appIcon_id=234881030,appLabel_id=234881025 WHERE bundle_name='com.huawei.hmos.browser';
UPDATE gridlayout_info SET appIcon_id=285212675,appLabel_id=285212672 WHERE bundle_name='com.huawei.hmos.camera';
CREATE TRIGGER naturalbase_rdb_gridlayout_info_ON_INSERT AFTER INSERT ON 'gridlayout_info' FOR EACH ROW BEGIN
UPDATE naturalbase_rdb_aux_metadata SET value=value+1 WHERE key=x'6e61747572616c626173655f7264625f6175785f637572736f725f677269646c61796f75745f696e666f';
INSERT OR REPLACE INTO naturalbase_rdb_aux_gridlayout_info_log (data_key, device, ori_device, timestamp, wtimestamp, flag, hash_key, cloud_gid, extend_field, cursor, version, sharing_resource, status) VALUES (new._rowid_, '', '', get_raw_sys_time(), get_raw_sys_time(), 0x02, calc_hash(NEW.'_id', 0), '', json_object('_id',NEW._id), (SELECT value FROM naturalbase_rdb_aux_metadata WHERE key=x'6e61747572616c626173655f7264625f6175785f637572736f725f677269646c61796f75745f696e666f'), '', '', 0);
SELECT client_observer('gridlayout_info', NEW._rowid_, 0, 1);
END;
CREATE TRIGGER naturalbase_rdb_gridlayout_info_ON_UPDATE AFTER UPDATE ON 'gridlayout_info' FOR EACH ROW BEGIN
UPDATE naturalbase_rdb_aux_metadata SET value=value+1 WHERE key=x'6e61747572616c626173655f7264625f6175785f637572736f725f677269646c61796f75745f696e666f' AND CASE WHEN ((NEW._id IS NOT OLD._id) OR (NEW.ability_name IS NOT OLD.ability_name) OR (NEW.appIcon_id IS NOT OLD.appIcon_id) OR (NEW.app_index IS NOT OLD.app_index) OR (NEW.app_status IS NOT OLD.app_status) OR (NEW.bundle_name IS NOT OLD.bundle_name) OR (NEW.column IS NOT OLD.column) OR (NEW.container IS NOT OLD.container) OR (NEW.height IS NOT OLD.height) OR (NEW.info_id IS NOT OLD.info_id) OR (NEW.info_name IS NOT OLD.info_name) OR (NEW.intent IS NOT OLD.intent) OR (NEW.module_name IS NOT OLD.module_name) OR (NEW.page_index IS NOT OLD.page_index) OR (NEW.row IS NOT OLD.row) OR (NEW.shortcut_id IS NOT OLD.shortcut_id) OR (NEW.type_id IS NOT OLD.type_id) OR (NEW.width IS NOT OLD.width)) THEN 1 ELSE 0 END;
UPDATE naturalbase_rdb_aux_gridlayout_info_log SET timestamp=get_raw_sys_time(), device='', flag=0x02, extend_field=json_object('_id',NEW._id), cursor=CASE WHEN ((NEW._id IS NOT OLD._id) OR (NEW.ability_name IS NOT OLD.ability_name) OR (NEW.appIcon_id IS NOT OLD.appIcon_id) OR (NEW.app_index IS NOT OLD.app_index) OR (NEW.app_status IS NOT OLD.app_status) OR (NEW.bundle_name IS NOT OLD.bundle_name) OR (NEW.column IS NOT OLD.column) OR (NEW.container IS NOT OLD.container) OR (NEW.height IS NOT OLD.height) OR (NEW.info_id IS NOT OLD.info_id) OR (NEW.info_name IS NOT OLD.info_name) OR (NEW.intent IS NOT OLD.intent) OR (NEW.module_name IS NOT OLD.module_name) OR (NEW.page_index IS NOT OLD.page_index) OR (NEW.row IS NOT OLD.row) OR (NEW.shortcut_id IS NOT OLD.shortcut_id) OR (NEW.type_id IS NOT OLD.type_id) OR (NEW.width IS NOT OLD.width)) THEN (SELECT value FROM naturalbase_rdb_aux_metadata WHERE key=x'6e61747572616c626173655f7264625f6175785f637572736f725f677269646c61796f75745f696e666f') ELSE cursor END WHERE data_key=OLD._rowid_;
SELECT client_observer('gridlayout_info', OLD._rowid_, 1, CASE WHEN ((NEW._id IS NOT OLD._id) OR (NEW.ability_name IS NOT OLD.ability_name) OR (NEW.appIcon_id IS NOT OLD.appIcon_id) OR (NEW.app_index IS NOT OLD.app_index) OR (NEW.app_status IS NOT OLD.app_status) OR (NEW.bundle_name IS NOT OLD.bundle_name) OR (NEW.column IS NOT OLD.column) OR (NEW.container IS NOT OLD.container) OR (NEW.height IS NOT OLD.height) OR (NEW.info_id IS NOT OLD.info_id) OR (NEW.info_name IS NOT OLD.info_name) OR (NEW.intent IS NOT OLD.intent) OR (NEW.module_name IS NOT OLD.module_name) OR (NEW.page_index IS NOT OLD.page_index) OR (NEW.row IS NOT OLD.row) OR (NEW.shortcut_id IS NOT OLD.shortcut_id) OR (NEW.type_id IS NOT OLD.type_id) OR (NEW.width IS NOT OLD.width)) THEN 1 ELSE 0 END);
END;
CREATE TRIGGER naturalbase_rdb_gridlayout_info_ON_DELETE BEFORE DELETE ON 'gridlayout_info' FOR EACH ROW BEGIN
UPDATE naturalbase_rdb_aux_metadata SET value=value+1 WHERE key=x'6e61747572616c626173655f7264625f6175785f637572736f725f677269646c61796f75745f696e666f';
UPDATE naturalbase_rdb_aux_gridlayout_info_log SET data_key=-1,flag=0x03,timestamp=get_raw_sys_time(),extend_field=json_object('_id',OLD._id),cursor=(SELECT value FROM naturalbase_rdb_aux_metadata WHERE key=x'6e61747572616c626173655f7264625f6175785f637572736f725f677269646c61796f75745f696e666f') WHERE data_key=OLD._rowid_;
SELECT client_observer('gridlayout_info', -1, 2, 1);
END;
COMMIT;
