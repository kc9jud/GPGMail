/* GMKeyManager.m created by Lukas Pitschl (@lukele) on Wed 13-Jun-2013 */

/*
 * Copyright (c) 2000-2013, GPGTools Team <team@gpgtools.org>
 * All rights reserved.
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *     * Redistributions of source code must retain the above copyright
 *       notice, this list of conditions and the following disclaimer.
 *     * Redistributions in binary form must reproduce the above copyright
 *       notice, this list of conditions and the following disclaimer in the
 *       documentation and/or other materials provided with the distribution.
 *     * Neither the name of GPGTools nor the names of GPGMail
 *       contributors may be used to endorse or promote products
 *       derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE GPGTools Team ``AS IS'' AND ANY
 * EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED. IN NO EVENT SHALL THE GPGTools Team BE LIABLE FOR ANY
 * DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 * ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 * (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <Libmacgpg/Libmacgpg.h>
#import "CCLog.h"
#import "GPGMail_Prefix.pch"
#import "GPGMailBundle.h"
#import "NSSet+Functional.h"
#import "NSString+GPGMail.h"
#import "GMKeyManager.h"
#define restrict
#import <RegexKit/RegexKit.h>


const double kGMKeyManagerDelayInSecondsForInitialKeyLoad = 4;

@interface GMKeyManager ()

@property (nonatomic, strong) GPGController *gpgc;

// Key caches
@property (nonatomic, assign) dispatch_queue_t keysUpdateQueue;
@property (nonatomic, strong, readwrite) NSMutableSet *allKeys;
@property (nonatomic, strong) NSSet *secretKeys;
@property (nonatomic, strong) NSDictionary *secretKeysByID;
@property (nonatomic, strong) NSDictionary *secretKeysByEmail;
@property (nonatomic, strong) NSDictionary *secretKeyMap;
@property (nonatomic, strong) NSSet *publicKeys;
@property (nonatomic, strong) NSDictionary *publicKeysByID;
@property (nonatomic, strong) NSDictionary *publicKeysByEmail;
@property (nonatomic, strong) NSDictionary *publicKeyMap;
@property (nonatomic, strong) NSDictionary *groups;

@end


@implementation GMKeyManager

@synthesize gpgc = _gpgc, keysUpdateQueue = _keysUpdateQueue, allKeys = _allKeys, secretKeys = _secretKeys,
secretKeysByID = _secretKeysByID, secretKeysByEmail = _secretKeysByEmail, secretKeyMap = _secretKeyMap, publicKeys = _publicKeys, publicKeysByID = _publicKeysByID, publicKeysByEmail = _publicKeysByEmail,
publicKeyMap = _publicKeyMap, groups = _groups;

- (id)sharedInstance {
	static dispatch_once_t onceToken;
	static GMKeyManager *_instance;
	dispatch_once(&onceToken, ^{
		_instance = [[GMKeyManager alloc] init];
	});
	return _instance;
}

- (id)init {
	if(self = [super init]) {
		_gpgc = nil;
		_allKeys = nil;
		_keysUpdateQueue = dispatch_queue_create("org.gpgmail.keys", NULL);
	}
	
	return self;
}

#pragma mark - Public API

- (BOOL)secretKeyExistsForAddress:(NSString *)address {
	return [[self keysForAddresses:@[address] onlySecret:YES stopOnFound:YES] count] > 0;
}

- (BOOL)publicKeyExistsForAddress:(NSString *)address {
	return [[self keysForAddresses:@[address] onlySecret:NO stopOnFound:YES] count];
}

- (GPGKey *)keyForFingerprint:(NSString *)fingerprint {
	GPGKey *key = [self.allKeys member:fingerprint];
	// If no key matches, check the subkeys.
	if(key)
		return key;
	
	for(key in self.allKeys) {
		NSUInteger index = [key.subkeys indexOfObject:fingerprint];
		if(index != NSNotFound)
			break;
	}
	return key;
}

- (GPGKey *)secretKeyForKeyID:(NSString *)keyID {
	return (self.secretKeysByID)[keyID];
}

- (NSMutableSet *)signingKeyListForAddress:(NSString *)address {
    return [self keysForAddresses:@[[address gpgNormalizedEmail]] onlySecret:YES stopOnFound:NO];
}

- (NSMutableSet *)publicKeyListForAddresses:(NSArray *)addresses {
    NSMutableSet *normalizedAddresses = [NSMutableSet set];
    for (NSString *address in addresses) {
        [normalizedAddresses addObject:[address gpgNormalizedEmail]];
    }
    
    return [self keysForAddresses:[normalizedAddresses allObjects] onlySecret:NO stopOnFound:NO];
}

- (void)scheduleInitialKeyUpdate {
	[self scheduleInitialKeyUpdateAfterSeconds:kGMKeyManagerDelayInSecondsForInitialKeyLoad];
}

#pragma mark -

- (GPGController *)gpgc {
	static dispatch_once_t onceToken;
	
	typeof(self) __weak weakSelf = self;
    dispatch_once(&onceToken, ^{
		GMKeyManager *strongSelf = weakSelf;
		if(!strongSelf)
			return;
		strongSelf->_gpgc = [[GPGController alloc] init];
		strongSelf->_gpgc.delegate = strongSelf;
	});
	return _gpgc;
}

- (void)scheduleInitialKeyUpdateAfterSeconds:(double)seconds {
	// The keys should loaded after a specified period of time,
	dispatch_time_t delay = dispatch_time(DISPATCH_TIME_NOW, (int64_t)seconds * NSEC_PER_SEC);
	typeof(self) __weak weakSelf = self;
	dispatch_queue_t keysUpdateQueue = self.keysUpdateQueue;
	dispatch_after(delay, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^(void){
		// This is only necessary if the keys were not already fetched earlier.
		GMKeyManager *strongSelf = weakSelf;
		if(!strongSelf)
			return;
		if(!strongSelf->_allKeys)
			[strongSelf updateKeys:nil onQueue:keysUpdateQueue asynchronously:YES];
	});
}

- (void)gpgController:(GPGController *)gpgc keysDidChanged:(NSObject<EnumerationList> *)keys external:(BOOL)external {
    [self updateKeys:keys onQueue:_keysUpdateQueue asynchronously:YES];
}

- (void)updateKeys:(NSObject <EnumerationList> *)keys onQueue:(dispatch_queue_t)queue asynchronously:(BOOL)asynchronously {
	
	typeof(self) __weak weakSelf = self;
	dispatch_block_t _updateKeys = ^{
		GMKeyManager *strongSelf = weakSelf;
		if(!strongSelf)
			return;
		
		NSMutableSet *realKeys = [[NSMutableSet alloc] initWithCapacity:[keys count]];
		
		// Replace fingerprints with the actual GPGKeys keys.
		Class keyClass = [GPGKey class];
		for(__strong id key in keys) {
			if(![key isKindOfClass:keyClass]) {
				GPGKey *tempKey = [strongSelf->_allKeys member:key];
				if(tempKey)
					key = tempKey;
			}
			[realKeys addObject:key];
		}
		
		NSSet *updatedKeys = nil;
		if([realKeys count] == 0) {
			// Update all keys.
			updatedKeys = [strongSelf.gpgc updateKeys:strongSelf->_allKeys searchFor:nil withSigs:NO];
		}
		else {
			// Update only the keys in realKeys.
			updatedKeys = [strongSelf.gpgc updateKeys:keys withSigs:NO];
		}
		
		// Check for errors.
		if(strongSelf.gpgc.error) {
			if([strongSelf.gpgc.error isKindOfClass:[GPGException class]]) {
				DebugLog(@"%@: failed - %@ (Error text: %@)", NSStringFromSelector(_cmd), strongSelf.gpgc.error, ((GPGException *)strongSelf.gpgc.error).gpgTask.errText);
			}
			else if([strongSelf.gpgc.error isKindOfClass:[NSException class]]) {
				DebugLog(@"%@: unknown error - %@", NSStringFromSelector(_cmd), strongSelf.gpgc.error);
			}
			return;
		}
		
		// No errors, great, let's continue.
		if([realKeys count] == 0)
			realKeys = strongSelf->_allKeys;
		
		NSMutableSet *keysToRemove = [realKeys mutableCopy];
		[keysToRemove minusSet:updatedKeys];
		
		[strongSelf->_allKeys minusSet:keysToRemove];
		[strongSelf->_allKeys unionSet:updatedKeys];
		
		keysToRemove = nil;
		
		// Flush the key caches so they are recreated on request.
		[strongSelf rebuildKeyCaches];
		
		dispatch_async(dispatch_get_main_queue(), ^{
			[[NSNotificationCenter defaultCenter] postNotificationName:GPGMailKeyringUpdatedNotification object:strongSelf];
		});
	};
	
	// If no queue is set, simply execute the block.
	if(!queue)
		_updateKeys();
	else {
		if(asynchronously)
			dispatch_async(queue, _updateKeys);
		else
			dispatch_sync(queue, _updateKeys);
	}
}

#pragma mark - Getters for lazy key cache loading.

- (NSMutableSet *)allKeys {
	typeof(self) __weak weakSelf = self;
	
	dispatch_sync(_keysUpdateQueue, ^{
		typeof(weakSelf) __strong strongSelf = weakSelf;
		if(!strongSelf->_allKeys) {
			strongSelf->_allKeys = [[NSMutableSet alloc] init];
			[strongSelf updateKeys:nil onQueue:NULL asynchronously:NO];
		}
	});
	return _allKeys;
}

- (NSSet *)secretKeys {
	// Load all keys if not already available.
	// This will also rebuild the caches if the keys
	// are not yet available.
	[self allKeys];
	return _secretKeys;
}

- (void)rebuildSecretKeysCache {
	NSSet *secretKeys = [_allKeys filter:^id (GPGKey *key) {
		// Only either the key or one of the subkeys has to be valid,
		// non-expired, non-disabled, non-revoked and be used for signing.
		// We don't care about ownerTrust, validity.
		if(key.secret && key.canSign && key.status < GPGKeyStatus_Invalid)
			return key;
				
		return nil;
	}];
	self.secretKeys = secretKeys;
}

- (NSSet *)publicKeys {
	[self allKeys];
	return _publicKeys;
}

- (void)rebuildPublicKeysCache {
	NSSet *publicKeys = [_allKeys filter:^id (GPGKey *key) {
		// Only either the key or one of the subkeys has to be valid,
		// non-expired, non-disabled, non-revoked and be used for signing.
		// We don't care about ownerTrust, validity.
		if(key.canAnyEncrypt && key.status < GPGKeyStatus_Invalid)
			return key;
				
		return nil;
	}];
	self.publicKeys	= publicKeys;
}

- (NSDictionary *)publicKeysByID {
	[self allKeys];
	return _publicKeysByID;
}

- (void)rebuildPublicKeysByIDCache {
	NSMutableDictionary *map = [[NSMutableDictionary alloc] init];
	for(GPGKey *key in _publicKeys) {
		[map setValue:key forKey:key.keyID];
		for(GPGKey *subkey in key.subkeys)
			[map setValue:subkey forKey:subkey.keyID];
	}
	self.publicKeysByID = map;
}

- (NSDictionary *)secretKeysByID {
	[self allKeys];
	return _secretKeysByID;
}

- (void)rebuildSecretKeysByIDCache {
	NSMutableDictionary *map = [[NSMutableDictionary alloc] init];
	for(GPGKey *key in _secretKeys) {
		[map setValue:key forKey:key.keyID];
		for(GPGKey *subkey in key.subkeys)
			[map setValue:subkey forKey:subkey.keyID];
	}
	self.secretKeysByID = map;
}

- (NSDictionary *)publicKeysByEmail {
	[self allKeys];
	return _publicKeysByEmail;
}

- (void)rebuildPublicKeysByEmailCache {
	NSMutableDictionary *map = [[NSMutableDictionary alloc] init];
	NSMutableDictionary *userIDEmailMap = [[NSMutableDictionary alloc] init];
	
	for(GPGKey *key in _publicKeys) {
		for(GPGUserID *userID in key.userIDs) {
			NSString *email = [userID.email gpgNormalizedEmail];
			if(!email)
				continue;
			
			if(!userIDEmailMap[email]) {
				NSMutableSet *set = [[NSMutableSet alloc] init];
				userIDEmailMap[email] = set;
			}
			[userIDEmailMap[email] addObject:userID];
		}
	}
	
	// Loop through the entire map and if an email address has multiple
	// matching user ids select the one that is best (newest or most trusted.)
	for(NSString *email in userIDEmailMap) {
		NSSet *userIDs = userIDEmailMap[email];
		if([userIDs count] == 1) {
			GPGKey *key = [[userIDs anyObject] primaryKey];
			map[email] = key;
			continue;
		}
		GPGKey *key = [self bestKeyOfUserIDs:userIDs];
		map[email] = key;
	}
	
	self.publicKeysByEmail = map;
}


- (NSDictionary *)secretKeysByEmail {
	[self allKeys];
	return _secretKeysByEmail;
}

- (void)rebuildSecretKeysByEmailCache {
	// Checks for public keys which share the same email address and returns
    // a dictionary only including the most trusted and newest key with the email address.
	NSMutableDictionary *map = [[NSMutableDictionary alloc] init];
	
	for(GPGKey *key in _secretKeys) {
		for(GPGUserID *userID in key.userIDs) {
			NSString *email = [userID.email gpgNormalizedEmail];
			if(!email)
				continue;
			
			if(!map[email]) {
				NSMutableSet *list = [[NSMutableSet alloc] init];
				map[email] = list;
			}
			[map[email] addObject:key];
		}
	}
	
	self.secretKeysByEmail = map;
}

- (NSDictionary *)groups {
	[self allKeys];
	return _groups;
	
}

- (void)rebuildGroupsCache {
	NSDictionary *groups = [[GPGOptions sharedOptions] valueForKey:@"group"];
	NSMutableDictionary *cleanGroups = [[NSMutableDictionary alloc] init];
	
	for (NSString *email in groups) {
		NSArray *keyHints = groups[email];
		BOOL allKeysValid = YES;
		NSMutableSet *keys = [[NSMutableSet alloc] init];
		for (NSString *keyHint in keyHints) {
			GPGKey *key = [self findKeyByHint:keyHint onlySecret:NO];
			if (!key) {
				allKeysValid = NO;
				break;
			}
			[keys addObject:key];
		}
		if (allKeysValid)
			cleanGroups[[email gpgNormalizedEmail]] = keys;
	}
	
	self.groups = cleanGroups;
}

- (NSDictionary *)publicKeyMap {
	[self allKeys];
	return _publicKeyMap;
}

- (void)rebuildPublicKeyMapCache {
	NSMutableDictionary *keyMap = [[NSMutableDictionary alloc] init];
	[keyMap addEntriesFromDictionary:_publicKeysByEmail];
	[keyMap addEntriesFromDictionary:_groups];
	[keyMap addEntriesFromDictionary:[self userMappedKeysSecretOnly:NO]];
	
	self.publicKeyMap = keyMap;
}

- (NSDictionary *)secretKeyMap {
	[self allKeys];
	return _secretKeyMap;
}

- (void)rebuildSecretKeyMapCache {
	NSMutableDictionary *keyMap = [[NSMutableDictionary alloc] init];
	[keyMap addEntriesFromDictionary:_secretKeysByEmail];
	[keyMap addEntriesFromDictionary:[self userMappedKeysSecretOnly:YES]];
	
	self.secretKeyMap = keyMap;
}

- (void)rebuildKeyCaches {
	self.secretKeys = nil;
	self.secretKeysByID = nil;
	self.secretKeyMap = nil;
	self.secretKeysByEmail = nil;
	
	self.publicKeys = nil;
	self.publicKeysByID = nil;
	self.publicKeyMap = nil;
	self.publicKeysByEmail = nil;
	
	self.groups = nil;
	
	// First the two main key caches have to be rebuilt.
	// All other caches are based on these.
	[self rebuildSecretKeysCache];
	// Rebuild the public key cache.
	[self rebuildPublicKeysCache];
	
	dispatch_group_t cachesGroup = dispatch_group_create();
	
	typeof(self) __weak weakSelf = self;
	
	dispatch_group_async(cachesGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
		[weakSelf rebuildSecretKeysByEmailCache];
	});
	dispatch_group_async(cachesGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
		[weakSelf rebuildPublicKeysByEmailCache];
	});
	dispatch_group_async(cachesGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
		[weakSelf rebuildSecretKeysByIDCache];
	});
	dispatch_group_async(cachesGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
		[weakSelf rebuildPublicKeysByIDCache];
	});
	dispatch_group_async(cachesGroup, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
		[weakSelf rebuildGroupsCache];
	});
	
	// The secretKeyMap and publicKeyMap are based on all the previous
	// caches, so they have to finish to be rebuilt.
	dispatch_group_wait(cachesGroup, DISPATCH_TIME_FOREVER);
	dispatch_release(cachesGroup);
	
	[self rebuildSecretKeyMapCache];
	[self rebuildPublicKeyMapCache];
}

#pragma mark - Key helper methods

- (NSMutableSet *)keysForAddresses:(NSArray *)addresses onlySecret:(BOOL)onlySecret stopOnFound:(BOOL)stop {
    Class regexClass = [RKRegex class];
	Class setClass = [NSSet class];
    Class arrayClass = [NSArray class];
	NSDictionary *map = onlySecret ? self.secretKeyMap : self.publicKeyMap;
    NSString *allAdresses = [addresses componentsJoinedByString:@"\n"];
    NSMutableSet *keys = [NSMutableSet set];
    
    for (id identifier in map) {
        if ([identifier isKindOfClass:regexClass] ? [allAdresses isMatchedByRegex:identifier] : [addresses containsObject:identifier]) {
			id object = map[identifier];
			if([object isKindOfClass:setClass])
				[keys addObjectsFromArray:[object allObjects]];
			else if([object isKindOfClass:arrayClass])
				[keys addObjectsFromArray:object];
			else
				[keys addObject:object];
			
            if (stop)
				break;
        }
    }
    return keys;
}

- (GPGKey *)findKeyByHint:(NSString *)hint onlySecret:(BOOL)onlySecret {
    GPGKey *foundKey = nil;
    if(!hint)
        return nil;
    
    NSSet *keys = onlySecret ? _secretKeys : _publicKeys;
    for (GPGKey *key in keys) {
        if([key.textForFilter rangeOfString:hint].location != NSNotFound) {
            foundKey = key;
            break;
        }
    }
    return foundKey;
}

- (NSDictionary *)userMappedKeysSecretOnly:(BOOL)secretOnly {
    NSMutableDictionary *mappedKeys = [[NSMutableDictionary alloc] init];
    BOOL needWrite = NO;
    GPGOptions *options = [GPGOptions sharedOptions];
    
    NSDictionary *oldMap = [options valueInStandardDefaultsForKey:@"PublicKeyUserMap"];
    if (oldMap) {
        needWrite = YES;
        [mappedKeys addEntriesFromDictionary:oldMap];
        [options setValueInStandardDefaults:nil forKey:@"PublicKeyUserMap"];
    }
    oldMap = [options valueInCommonDefaultsForKey:@"PublicKeyUserMap"];
    if (oldMap) {
        needWrite = YES;
        [mappedKeys addEntriesFromDictionary:oldMap];
        [options setValueInCommonDefaults:nil forKey:@"PublicKeyUserMap"];
    }
    
    
    /* "KeyMapping" is a dictionary the form @{@"Address": @"KeyID", @"*@domain.com": @"Fingerprint", @"Address": @[@"KeyID", @"Name", @"Fingerprint"]} */
    [mappedKeys addEntriesFromDictionary:[options valueInCommonDefaultsForKey:@"KeyMapping"]];
    
    if (needWrite) {
        [options setValueInCommonDefaults:mappedKeys forKey:@"KeyMapping"];
    }
    
	Class stringClass = [NSString class];
	Class arrayClass = [NSArray class];
    
    NSMutableDictionary *cleanMappedKeys = [NSMutableDictionary dictionary];
    for (__strong NSString *pattern in mappedKeys) {
        id keyIdentifier = mappedKeys[pattern];
        id object = nil;
        
        if ([keyIdentifier isKindOfClass:stringClass]) {
            object = [self findKeyByHint:keyIdentifier onlySecret:secretOnly];
        } else if ([keyIdentifier isKindOfClass:arrayClass]) {
            NSMutableArray *keys = [NSMutableArray array];
            for (NSString *hint in keyIdentifier) {
                GPGKey *key = [self findKeyByHint:hint onlySecret:secretOnly];
                if (key) {
                    [keys addObject:key];
                    object = keys;
                }
            }
        }
        
        
        if ([pattern rangeOfString:@"*"].length > 0) {
            NSString *regexString =  [NSString stringWithFormat:@"^%@$", [[NSRegularExpression escapedPatternForString:pattern] stringByReplacingOccurrencesOfString:@"\\*" withString:@".*"]];
            pattern = [RKRegex regexWithRegexString:regexString library:RKRegexPCRELibrary options:RKCompileCaseless | RKCompileMultiline error:nil];
        } else {
            pattern = [pattern gpgNormalizedEmail];
        }
        
        if (object)
            cleanMappedKeys[pattern] = object;
    }
    
    return cleanMappedKeys;
}

- (GPGKey *)bestKeyOfUserIDs:(NSSet *)userIDs {
    // First check if any trusted keys are in there, if so, sort them by date.
    NSMutableArray *secretUserIDs = [[NSMutableArray alloc] init];
    NSMutableArray *trustedUserIDs = [[NSMutableArray alloc] init];
    NSMutableArray *untrustedUserIDs = [[NSMutableArray alloc] init];
    for(GPGUserID *userID in userIDs) {
        if (userID.primaryKey.secret) {
            [secretUserIDs addObject:userID];
        } else if(userID.validity >= 3) {
            [trustedUserIDs addObject:userID];
        } else {
            [untrustedUserIDs addObject:userID];
        }
    }
    
    NSSortDescriptor *dateSorter = [[NSSortDescriptor alloc] initWithKey:@"creationDate" ascending:NO comparator:^NSComparisonResult(id obj1, id obj2) {
        return [(NSDate *)obj1 compare:obj2];
    }];
    
    NSArray *sortedUserIDs = nil;
    if (secretUserIDs.count) {
        sortedUserIDs = secretUserIDs;
    } else if (trustedUserIDs.count) {
        sortedUserIDs = trustedUserIDs;
    } else {
        sortedUserIDs = untrustedUserIDs;
    }
    
    sortedUserIDs = [sortedUserIDs sortedArrayUsingDescriptors:@[dateSorter]];
    
    
    return ((GPGUserID *)sortedUserIDs[0]).primaryKey;
}

#pragma mark - Cleaning up

- (void)dealloc {
	dispatch_release(_keysUpdateQueue);
}

@end
