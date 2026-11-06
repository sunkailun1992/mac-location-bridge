// Experimental scoped leaf anchor with an undocumented zero allowed-error setting.
// No trust mutation occurs without explicit apply/restore. Root trust is never granted.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#define K(x) ((__bridge NSString *)(x))
static NSString *const appPath = @"/usr/libexec/locationd";
static NSString *const ack = @"--confirm-experimental-leaf-anchor-zero";
static NSString *const variant = @"leaf-anchor-allowed-error-zero-v1";
static NSArray *hosts(void) { return @[@"gs-loc.apple.com", @"gs-loc-cn.apple.com"]; }
static void need(BOOL ok, NSString *why) { if (!ok) @throw [NSException exceptionWithName:@"Helper" reason:why userInfo:nil]; }
static void statusOK(OSStatus s, NSString *op) { need(s == errSecSuccess, [NSString stringWithFormat:@"%@_status_%d",op,(int)s]); }
static NSString *sha(NSData *d) { unsigned char h[32]; CC_SHA256(d.bytes,(CC_LONG)d.length,h); NSMutableString *s=[NSMutableString string]; for(int i=0;i<32;i++) [s appendFormat:@"%02x",h[i]]; return s; }
static void output(NSDictionary *o) { NSData *d=[NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:NULL]; fwrite(d.bytes,1,d.length,stdout); puts(""); }
static NSData *certDER(NSString *path) {
    NSData *d=[NSData dataWithContentsOfFile:path]; need(d!=nil,@"certificate_read_failed");
    NSString *s=[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if ([s containsString:@"-----BEGIN CERTIFICATE-----"]) {
        NSRange a=[s rangeOfString:@"-----BEGIN CERTIFICATE-----"], b=[s rangeOfString:@"-----END CERTIFICATE-----"];
        need(b.location>a.location,@"invalid_certificate_pem");
        NSString *v=[s substringWithRange:NSMakeRange(NSMaxRange(a),b.location-NSMaxRange(a))];
        d=[[NSData alloc] initWithBase64EncodedString:v options:NSDataBase64DecodingIgnoreUnknownCharacters];
    }
    SecCertificateRef c=SecCertificateCreateWithData(NULL,(__bridge CFDataRef)d); need(c!=NULL,@"invalid_certificate");
    NSData *der=CFBridgingRelease(SecCertificateCopyData(c)); CFRelease(c); return der;
}
static SecCertificateRef cert(NSData *d) { SecCertificateRef c=SecCertificateCreateWithData(NULL,(__bridge CFDataRef)d); need(c!=NULL,@"invalid_certificate"); return c; }
static NSData *applicationRequirement(void) {
    SecStaticCodeRef code=NULL; SecRequirementRef req=NULL; CFDataRef data=NULL;
    statusOK(SecStaticCodeCreateWithPath((__bridge CFURLRef)[NSURL fileURLWithPath:appPath],kSecCSDefaultFlags,&code),@"locationd_static_code");
    statusOK(SecStaticCodeCheckValidity(code,kSecCSStrictValidate,NULL),@"locationd_signature");
    statusOK(SecCodeCopyDesignatedRequirement(code,kSecCSDefaultFlags,&req),@"locationd_requirement");
    statusOK(SecRequirementCopyData(req,kSecCSDefaultFlags,&data),@"locationd_requirement_data");
    CFRelease(req); CFRelease(code); return CFBridgingRelease(data);
}
// Read-only SPI: CopyData returns only a path, not the signing constraint.
static NSData *trustedRequirement(SecTrustedApplicationRef app) {
    typedef OSStatus (*CopyReq)(SecTrustedApplicationRef,SecRequirementRef *);
    CopyReq f=(CopyReq)dlsym(RTLD_DEFAULT,"SecTrustedApplicationCopyRequirement"); need(f!=NULL,@"application_requirement_inspection_unavailable");
    SecRequirementRef req=NULL; CFDataRef data=NULL; statusOK(f(app,&req),@"trusted_application_requirement"); need(req!=NULL,@"missing_application_requirement");
    statusOK(SecRequirementCopyData(req,kSecCSDefaultFlags,&data),@"trusted_requirement_data"); CFRelease(req); return CFBridgingRelease(data);
}
static NSDictionary *osInfo(void) { NSDictionary *p=[NSDictionary dictionaryWithContentsOfFile:@"/System/Library/CoreServices/SystemVersion.plist"]; return @{@"version":p[@"ProductVersion"]?:@"unknown",@"build":p[@"ProductBuildVersion"]?:@"unknown"}; }
static NSArray *constraints(NSData *requirement) {
    SecTrustedApplicationRef app=NULL; statusOK(SecTrustedApplicationCreateFromPath(appPath.UTF8String,&app),@"locationd_application");
    need([trustedRequirement(app) isEqual:requirement],@"locationd_application_requirement_mismatch");
    SecPolicyRef policy=SecPolicyCreateSSL(true,NULL); need(policy!=NULL,@"ssl_policy_creation_failed");
    NSMutableArray *a=[NSMutableArray array];
    for(NSString *host in hosts()) [a addObject:@{K(kSecTrustSettingsPolicy):(__bridge id)policy,K(kSecTrustSettingsApplication):(__bridge id)app,K(kSecTrustSettingsPolicyString):host,K(kSecTrustSettingsAllowedError):@0,K(kSecTrustSettingsResult):@2}];
    CFRelease(policy); CFRelease(app); return a;
}
static NSDictionary *trustSummary(SecCertificateRef c, SecTrustSettingsDomain domain) {
    CFArrayRef a=NULL; OSStatus s=SecTrustSettingsCopyTrustSettings(c,domain,&a);
    need(s==errSecSuccess || s==errSecItemNotFound || s==errSecNoTrustSettings,@"trust_settings_read_failed");
    NSDictionary *r=@{@"status":@(s),@"count":@(a?CFArrayGetCount(a):0)}; if(a) CFRelease(a); return r;
}
static NSDictionary *evaluation(NSData *leaf, NSData *root, NSString *host) {
    SecCertificateRef l=cert(leaf),r=cert(root); SecPolicyRef p=host?SecPolicyCreateSSL(true,(__bridge CFStringRef)host):SecPolicyCreateBasicX509();
    SecTrustRef t=NULL; statusOK(SecTrustCreateWithCertificates((__bridge CFArrayRef)@[(__bridge id)l,(__bridge id)r],p,&t),@"create_trust");
    statusOK(SecTrustSetAnchorCertificates(t,(__bridge CFArrayRef)@[(__bridge id)r]),@"set_process_anchors");
    statusOK(SecTrustSetAnchorCertificatesOnly(t,true),@"process_anchors_only"); statusOK(SecTrustSetNetworkFetchAllowed(t,false),@"disable_network_fetch");
    CFErrorRef err=NULL; BOOL valid=SecTrustEvaluateWithError(t,&err); SecTrustResultType tr=kSecTrustResultInvalid; SecTrustGetTrustResult(t,&tr);
    NSDictionary *res=@{@"valid":@(valid),@"error":@(err?CFErrorGetCode(err):0),@"trustResult":@(tr)};
    if(err) CFRelease(err); CFRelease(t);CFRelease(p);CFRelease(l);CFRelease(r);return res;
}
static NSDictionary *plan(NSData *leaf,NSData *root,NSData *req) {
    need(![leaf isEqual:root],@"unexpected_leaf_fingerprint");
    need([evaluation(leaf,root,nil)[@"valid"] boolValue],@"leaf_root_basic_chain_invalid");
    (void)constraints(req);
    return @{@"domain":@"admin",@"application":appPath,@"hosts":hosts(),@"allowedError":@0,@"trustResult":@2,@"constraintCount":@2,@"variant":variant,@"experimentalLeafAnchor":@YES,@"noBroadTrust":@YES,@"addsRootTrust":@NO,@"rootUsedForOfflineChainValidationOnly":@YES,@"trustScope":@"single_leaf_two_exact_SSL_hosts_and_locationd_requirement",@"leafSHA256":sha(leaf),@"rootSHA256":sha(root),@"locationdRequirementSHA256":sha(req),@"systemTrustChanged":@NO,@"realLocationVerified":@NO,@"undocumentedExperimentalBehavior":@YES,@"os":osInfo()};
}
static void secureWrite(NSString *path,NSData *d) {
    int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);need(fd>=0,@"snapshot_file_already_exists_or_unwritable");
    size_t n=0;while(n<d.length){ssize_t w=write(fd,(const char *)d.bytes+n,d.length-n);if(w<=0){close(fd);need(NO,@"snapshot_write_failed");}n+=(size_t)w;}
    need(fsync(fd)==0,@"snapshot_fsync_failed");close(fd);
}
static void assertPrivate(NSString *path,BOOL directory) { struct stat st;need(lstat(path.fileSystemRepresentation,&st)==0,@"snapshot_missing");need(directory?S_ISDIR(st.st_mode):S_ISREG(st.st_mode),@"snapshot_not_regular"); need((st.st_mode&0777)==(directory?0700:0600),@"snapshot_permissions_not_private"); }
static NSDictionary *load(NSString *dir) {
    assertPrivate(dir,YES);NSString *path=[dir stringByAppendingPathComponent:@"baseline.plist"];assertPrivate(path,NO);
    NSDictionary *b=[NSPropertyListSerialization propertyListWithData:[NSData dataWithContentsOfFile:path] options:NSPropertyListImmutable format:NULL error:NULL];
    need([b isKindOfClass:NSDictionary.class]&&[b[@"schema"] isEqual:@1],@"invalid_snapshot");
    need([b[@"leaf"] isKindOfClass:NSData.class]&&[b[@"root"] isKindOfClass:NSData.class]&&[b[@"requirement"] isKindOfClass:NSData.class],@"invalid_snapshot_types");
    need([sha(b[@"leaf"]) isEqual:b[@"leafSHA256"]]&&[sha(b[@"root"]) isEqual:b[@"rootSHA256"]],@"snapshot_certificate_hash_mismatch");
    need([b[@"variant"] isEqual:variant],@"snapshot_variant_mismatch");
    need([b[@"allowedError"] isEqual:@0]&&[b[@"trustResult"] isEqual:@2]&&[b[@"constraintCount"] isEqual:@2]&&[b[@"application"] isEqual:appPath]&&[b[@"hosts"] isEqual:hosts()]&&[b[@"experimentalLeafAnchor"] isEqual:@YES]&&[b[@"noBroadTrust"] isEqual:@YES]&&[b[@"addsRootTrust"] isEqual:@NO],@"snapshot_constraint_parameters_mismatch");
    need([sha(b[@"requirement"]) isEqual:b[@"locationdRequirementSHA256"]],@"snapshot_requirement_hash_mismatch");
    need(![b[@"leaf"] isEqual:b[@"root"]],@"snapshot_leaf_equals_root");
    need([b[@"leafUserStatus"] intValue]==errSecItemNotFound&&[b[@"leafAdminStatus"] intValue]==errSecItemNotFound,@"snapshot_was_not_absent");return b;
}
static BOOL ownConstraints(CFArrayRef current,NSData *req) {
    if(!current||CFArrayGetCount(current)!=2)return NO;
    NSMutableSet *seen=[NSMutableSet set];
    for(NSDictionary *d in (__bridge NSArray *)current){
        if(![d isKindOfClass:NSDictionary.class]||(d.count!=5&&d.count!=6))return NO;
        // The macOS API persists the SSL policy name as an additional dictionary key.
        if(d.count==6&&![d[@"kSecTrustSettingsPolicyName"] isEqual:@"sslServer"])return NO;
        NSString *h=d[K(kSecTrustSettingsPolicyString)];if(![hosts() containsObject:h]||[seen containsObject:h])return NO;[seen addObject:h];
        if(![d[K(kSecTrustSettingsAllowedError)] isEqual:@0]||![d[K(kSecTrustSettingsResult)] isEqual:@2])return NO;
        CFTypeRef p=(__bridge CFTypeRef)d[K(kSecTrustSettingsPolicy)],a=(__bridge CFTypeRef)d[K(kSecTrustSettingsApplication)];
        if(!p||CFGetTypeID(p)!=SecPolicyGetTypeID()||!a||CFGetTypeID(a)!=SecTrustedApplicationGetTypeID())return NO;
        SecPolicyRef expected=SecPolicyCreateSSL(true,NULL);NSDictionary *ep=CFBridgingRelease(SecPolicyCopyProperties(expected)),*cp=CFBridgingRelease(SecPolicyCopyProperties((SecPolicyRef)p));CFRelease(expected);
        if(![ep isEqual:cp]||![trustedRequirement((SecTrustedApplicationRef)a) isEqual:req])return NO;
    }return seen.count==2;
}
static NSString *state(NSDictionary *b) {
    SecCertificateRef l=cert(b[@"leaf"]);CFArrayRef a=NULL;
    NSDictionary *us=trustSummary(l,kSecTrustSettingsDomainUser);need([us[@"status"] intValue]==errSecItemNotFound,@"user_leaf_settings_changed");
    OSStatus s=SecTrustSettingsCopyTrustSettings(l,kSecTrustSettingsDomainAdmin,&a);CFRelease(l);
    if(s==errSecItemNotFound)return @"baseline_absent";
    need(s==errSecSuccess,@"admin_leaf_read_failed");BOOL own=ownConstraints(a,b[@"requirement"]);CFRelease(a);need(own,@"admin_leaf_settings_not_ours");return @"experimental_constraints_present";
}
int main(int argc,const char *argv[]) { @autoreleasepool { @try {
    need(argc>=2,@"usage_plan_inspect_prepare_check_apply_restore"); NSString *command=@(argv[1]);
    BOOL mutation=[@[@"apply",@"restore"] containsObject:command];
    if(mutation){need(argc==4&&[@(argv[3]) isEqual:ack],@"explicit_mutation_confirmation_required");}
    if([@[@"plan",@"inspect",@"prepare"] containsObject:command]){
        need(argc==([command isEqual:@"prepare"]?5:4),@"wrong_argument_count");NSData *l=certDER(@(argv[2])),*r=certDER(@(argv[3])),*req=applicationRequirement();NSMutableDictionary *out=[plan(l,r,req) mutableCopy];
        SecCertificateRef leaf=cert(l),root=cert(r);NSDictionary *u=trustSummary(leaf,kSecTrustSettingsDomainUser),*a=trustSummary(leaf,kSecTrustSettingsDomainAdmin);
        out[@"leafUserStatus"]=u[@"status"];out[@"leafAdminStatus"]=a[@"status"];out[@"rootUser"]=trustSummary(root,kSecTrustSettingsDomainUser);out[@"rootAdmin"]=trustSummary(root,kSecTrustSettingsDomainAdmin);
        if([command isEqual:@"inspect"]){
            CFArrayRef current=NULL;OSStatus cs=SecTrustSettingsCopyTrustSettings(leaf,kSecTrustSettingsDomainAdmin,&current);
            BOOL exact=[u[@"status"] intValue]==errSecItemNotFound&&cs==errSecSuccess&&ownConstraints(current,req);
            if(current)CFRelease(current);out[@"locationdScopedTrustPresent"]=@(exact);
            NSMutableDictionary *ev=[NSMutableDictionary dictionary];for(NSString *host in hosts())ev[host]=evaluation(l,r,host);out[@"offlineSSL"]=ev;out[@"offlineCaller"] = @"this_helper_not_locationd";}
        if([command isEqual:@"prepare"]){
            need([u[@"status"] intValue]==errSecItemNotFound&&[a[@"status"] intValue]==errSecItemNotFound,@"existing_leaf_settings_refuse_to_replace");
            NSString *dir=@(argv[4]);need(mkdir(dir.fileSystemRepresentation,0700)==0,@"snapshot_directory_exists_or_unwritable");
            NSMutableDictionary *b=[out mutableCopy];b[@"schema"]=@1;b[@"leaf"]=l;b[@"root"]=r;b[@"requirement"]=req;b[@"createdAt"]=[NSDate date];
            NSData *data=[NSPropertyListSerialization dataWithPropertyList:b format:NSPropertyListBinaryFormat_v1_0 options:0 error:NULL];need(data!=nil,@"snapshot_serialization_failed");secureWrite([dir stringByAppendingPathComponent:@"baseline.plist"],data);out[@"snapshotCreated"]=@YES;
        }CFRelease(leaf);CFRelease(root);output(out);return 0;
    }
    need([@[@"check",@"apply",@"restore"] containsObject:command],@"unknown_command");need(argc==(mutation?4:3),@"wrong_argument_count");NSDictionary *b=load(@(argv[2]));NSString *s=state(b);
    if(mutation){
        if([command isEqual:@"apply"]){need([applicationRequirement() isEqual:b[@"requirement"]],@"locationd_changed_since_snapshot");need([osInfo() isEqual:b[@"os"]],@"os_changed_since_snapshot");}
        SecCertificateRef l=cert(b[@"leaf"]);
        if([command isEqual:@"apply"]){need([s isEqual:@"baseline_absent"],@"experiment_already_applied");NSArray *a=constraints(b[@"requirement"]);statusOK(SecTrustSettingsSetTrustSettings(l,kSecTrustSettingsDomainAdmin,(__bridge CFArrayRef)a),@"set_leaf_experimental_constraints");}
        else if([s isEqual:@"experimental_constraints_present"])statusOK(SecTrustSettingsRemoveTrustSettings(l,kSecTrustSettingsDomainAdmin),@"remove_own_leaf_constraints");
        CFRelease(l);s=state(b);need([s isEqual:([command isEqual:@"apply"]?@"experimental_constraints_present":@"baseline_absent")],@"mutation_readback_failed");
    }
    output(@{@"state":s,@"systemTrustChanged":@(mutation),@"realLocationVerified":@NO,@"leafSHA256":b[@"leafSHA256"]});return 0;
} @catch(NSException *e){output(@{@"error":e.reason?:@"failed",@"realLocationVerified":@NO});return 1;} } }
