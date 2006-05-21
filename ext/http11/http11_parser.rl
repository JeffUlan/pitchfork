/* Mongrel Web Server - A Mostly Ruby Webserver and Library
 *
 * Copyright (C) 2005 Zed A. Shaw zedshaw AT zedshaw dot com
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#include "http11_parser.h"
#include <stdio.h>
#include <assert.h>
#include <stdlib.h>
#include <ctype.h>
#include <string.h>

#define LEN(AT, FPC) (FPC - buffer - parser->AT)
#define MARK(M,FPC) (parser->M = (FPC) - buffer)
#define PTR_TO(F) (buffer + parser->F)

/** machine **/
%%{
	machine http_parser;

    	action mark {MARK(mark, fpc); }

	action start_field { MARK(field_start, fpc); }
	action write_field { 
	       parser->field_len = LEN(field_start, fpc);
	}

	action start_value { MARK(mark, fpc); }
	action write_value { 
	       if(parser->http_field != NULL) {
	       	       parser->http_field(parser->data, PTR_TO(field_start), parser->field_len, PTR_TO(mark), LEN(mark, fpc));
		}
	}
	action request_method { 
	       if(parser->request_method != NULL) 
	       	       parser->request_method(parser->data, PTR_TO(mark), LEN(mark, fpc));
	}
	action request_uri { 
	       if(parser->request_uri != NULL)
	       	       parser->request_uri(parser->data, PTR_TO(mark), LEN(mark, fpc));
	}
	action query_string { 
	       if(parser->query_string != NULL)
	       	       parser->query_string(parser->data, PTR_TO(mark), LEN(mark, fpc));
	}

	action http_version {	
	       if(parser->http_version != NULL)
	       	       parser->http_version(parser->data, PTR_TO(mark), LEN(mark, fpc));
	}

    	action done { 
	       parser->body_start = fpc - buffer + 1; 
	       if(parser->header_done != NULL)
	       	       parser->header_done(parser->data, fpc, 0);
	       fbreak;
	}


	#### HTTP PROTOCOL GRAMMAR
        # line endings
        CRLF = "\r\n";

        # character types
        CTL = (cntrl | 127);
        safe = ("$" | "-" | "_" | ".");
        extra = ("!" | "*" | "'" | "(" | ")" | ",");
        reserved = (";" | "/" | "?" | ":" | "@" | "&" | "=" | "+");
        unsafe = (CTL | " " | "\"" | "#" | "%" | "<" | ">");
        national = any -- (alpha | digit | reserved | extra | safe | unsafe);
        unreserved = (alpha | digit | safe | extra | national);
        escape = ("%" xdigit xdigit);
        uchar = (unreserved | escape);
        pchar = (uchar | ":" | "@" | "&" | "=" | "+");
        tspecials = ("(" | ")" | "<" | ">" | "@" | "," | ";" | ":" | "\\" | "\"" | "/" | "[" | "]" | "?" | "=" | "{" | "}" | " " | "\t");

        # elements
        token = (ascii -- (CTL | tspecials));

        # URI schemes and absolute paths
        scheme = ( alpha | digit | "+" | "-" | "." )* ;
        absolute_uri = (scheme ":" (uchar | reserved )*) >mark %request_uri;

        path = (pchar+ ( "/" pchar* )*) ;
        query = ( uchar | reserved )* >mark %query_string ;
        param = ( pchar | "/" )* ;
        params = (param ( ";" param )*) ;
        rel_path = (path? (";" params)?) %request_uri  ("?" query)? ;
        absolute_path = ("/"+ rel_path) >mark ;
        
        Request_URI = ("*" >mark %request_uri | absolute_uri | absolute_path) ;
        Method = (upper | digit | safe){1,20} >mark %request_method;
        
        http_number = (digit+ "." digit+) ;
        HTTP_Version = ("HTTP/" http_number) >mark %http_version ;
        Request_Line = (Method " " Request_URI " " HTTP_Version CRLF) ;
	
	field_name = (token -- ":")+ >start_field %write_field;

        field_value = any* >start_value %write_value;

        message_header = field_name ": " field_value :> CRLF;
	
        Request = Request_Line (message_header)* ( CRLF @done);

	main := Request;
}%%

/** Data **/
%% write data;

int http_parser_init(http_parser *parser)  {
    int cs = 0;
    %% write init;
    parser->cs = cs;
    parser->body_start = 0;
    parser->content_len = 0;
    parser->mark = 0;
    parser->nread = 0;
    parser->field_len = 0;
    parser->field_start = 0;    

    return(1);
}


/** exec **/
size_t http_parser_execute(http_parser *parser, const char *buffer, size_t len, size_t off)  {
    const char *p, *pe;
    int cs = parser->cs;

    assert(off <= len && "offset past end of buffer");

    p = buffer+off;
    pe = buffer+len;

    assert(*pe == '\0' && "pointer does not end on NUL");
    assert(pe - p == len - off && "pointers aren't same distance");


    %% write exec;

    parser->cs = cs;
    parser->nread += p - (buffer + off);

    assert(p <= pe && "buffer overflow after parsing execute");
    assert(parser->nread <= len && "nread longer than length");
    assert(parser->body_start <= len && "body starts after buffer end");
    assert(parser->mark < len && "mark is after buffer end");
    assert(parser->field_len <= len && "field has length longer than whole buffer");
    assert(parser->field_start < len && "field starts after buffer end");

    if(parser->body_start) {
        /* final \r\n combo encountered so stop right here */
	%%write eof;
	parser->nread++;
    }

    return(parser->nread);
}

int http_parser_finish(http_parser *parser)
{
	int cs = parser->cs;

	%%write eof;

	parser->cs = cs;

	if (http_parser_has_error(parser) ) {
		return -1;
	} else if (http_parser_is_finished(parser) ) {
		return 1;
	} else {
	       return 0;
	}
}

int http_parser_has_error(http_parser *parser) {
    return parser->cs == http_parser_error;
}

int http_parser_is_finished(http_parser *parser) {
    return parser->cs == http_parser_first_final;
}
