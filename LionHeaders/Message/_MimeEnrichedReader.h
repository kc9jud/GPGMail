/*
 *     Generated by class-dump 3.3.3 (64 bit).
 *
 *     class-dump is Copyright (C) 1997-1998, 2000-2001, 2004-2010 by Steve Nygard.
 */



@class NSMutableString;

@interface _MimeEnrichedReader : NSObject
{
    CDStruct_7e4886f7 _inputBuffer;
    long long _currentIndex;
    long long _inputLength;
    unsigned int _noFillLevel:30;
    unsigned int _eatOneNewline:1;
    unsigned int _insideComment:1;
    long long _lastQuoteLevel;
    struct __CFArray *_commandStack;
    id _outputString;
    NSMutableString *_outputBuffer;
    double _indentWidth;
    BOOL outputShouldBeHTML;
}

+ (id)punctuationSet;
+ (id)parenSet;
- (id)init;
- (void)dealloc;
- (void)finalize;
- (void)appendStringToBuffer:(id)arg1;
- (void)resetStateWithString:(id)arg1 outputString:(id)arg2;
- (void)nowWouldBeAGoodTimeToAppendToTheAttributedString;
- (void)fixConsecutiveSpaces:(id)arg1;
- (void)closeUpQuoting;
- (void)handleNoParameterCommand:(const CDStruct_3441fd00 *)arg1;
- (void)setupFontStackEntry:(struct _CommandStackEntry *)arg1;
- (void)beginCommand:(id)arg1;
- (void)endCommand:(id)arg1;
- (void)parseParameterString:(id)arg1;
- (id)currentFont;
- (int)readTokenInto:(id *)arg1;
- (void)convertRichTextString:(id)arg1 intoOutputString:(id)arg2;
- (void)convertEnrichedString:(id)arg1 intoOutputString:(id)arg2;
- (void)convertEnrichedString:(id)arg1 intoPlainOutputString:(id)arg2;

@end
