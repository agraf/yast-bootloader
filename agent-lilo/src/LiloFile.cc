/**
 * File:
 *   LiloFile.cc
 *
 * Module:
 *   lilo.conf agent
 *
 * Summary:
 *   lilo file internal representation
 *
 * Authors:
 *   dan.meszaros <dmeszar@suse.cz>
 *
 * $Id$
 *
 * lilo.conf file memory representation base class
 *
 */

#include "LiloSection.h"
#include "LiloFile.h"
#include <stdio.h>
#include <unistd.h>
#include <ycp/y2log.h>
#include <fstream>
#include <sstream>

#define headline "# Modified by YaST2. Last modification on"

liloFile::liloFile(string filename, const string& init_type) : options(init_type)
{
    fname=filename;
    file_contents = "";
    use_string = false;
    type = init_type;
}

liloFile::~liloFile()
{
}

bool liloFile::parse()
{
    string str;
    inputLine* li;
    liloSection* curSect=NULL;

    // erase old sections and options
    sections.erase(sections.begin(), sections.end());
    options.order.erase(options.order.begin(), options.order.end());

    istream * is;
    if (! use_string)
	is = new ifstream (fname.c_str());
    else
	is = new istringstream (file_contents);
    
    if(!is)
    {
	return false;
    }

    if (! *is)
    {
	delete is;
	return false;
    }

    string commentBuffer="";
    string tmp;

    bool retval = false;
    bool trail=true;

    int linecounter=0;

    while( *is)
    {
	
	getline(*is, str);
	linecounter++;
    
	if(linecounter==1)
	{
	    if(str.substr(0, strlen(headline))==headline)
	    {
		continue;
	    }
	}
	
	// parse the line
	li=new inputLine(str, type);

	if(commentBuffer!="")
	{
	    tmp=commentBuffer;
	    if(li->comment!="")
	    {
		tmp=tmp+"\n"+li->comment;
	    }
	    commentBuffer=tmp;
	}
	else
	{
	    commentBuffer=li->comment;
	}

	li->comment=commentBuffer;

	if(trail && strip(li->src)=="")
	{
	    comment=li->comment;
	    trail=false;
	    commentBuffer="";
	    continue;
	}		

	bool header = false;
	if (type == "grub")
	{
	    if (li->option == "title")
	    {
                curSect=new liloSection(type);
                curSect->processLine(li); 
                sections.push_back(curSect);
                retval=true;
                header = true;
	    }
	}
	else
	{
	    if(li->option=="image" || li->option=="other")
	    {
		curSect=new liloSection(type);
		curSect->processLine(li); 
		sections.push_back(curSect);
		retval=true;
		header = true;
	    }
	}
	if (! header)
	{
	    if(curSect)
	    {
		retval=curSect->processLine(li);
	    }
	    else
	    {	
		retval=options.processLine(li);
	    }
	}

	if(retval)
	{
	    commentBuffer="";
	    trail=false;
	}

	if(li)
	{	
	    delete li;
	    li=NULL;
	}
    }
    delete is; 
    return true;

}

bool liloFile::save(const char* filename)
{
    bool del=false;
    string fn;
    if(filename)
    {
	fn=filename;
    }
    else
    {
	fn=fname;
    }
    ostream * of;

    if (use_string)
	of = new ostringstream ();
    else
	of = new ofstream (fn.c_str());
    
    if(!of->good())
    {
	if(del) delete filename;
	delete of;
	return false;
    }

    time_t tim=time(NULL);

    *of << headline << " " << string(ctime(&tim)) << endl ;

    if(comment.length()>=0)
    {
	*of << comment << endl;
    }

    options.saveToFile(of, "");
    uint pos;

    for(pos=0; pos<sections.size(); pos++)
    {
	*of << endl;
	sections[pos]->saveToFile(of, "    ");
    }
    if (use_string)
    {
	const string tmp = (static_cast<ostringstream*>(of))->str ();
	file_contents = tmp;
    }
    delete of;
    return true;
}

bool liloFile::reread()
{
    return parse();
}

int liloFile::getSectPos(string sectname)
{
    uint pos;
    for(pos=0; pos<sections.size(); pos++)
    {
        if(sections[pos]->getSectName()==sectname)
        {
            break;
        }
    }

    if(pos<sections.size())
    {
	return pos;
    }
    else
    {
	return -1;
    }
}

liloSection* liloFile::getSectPtr(const YCPPath& path)
{
    if(path->length()<2)
    {
	return NULL;
    }
   
    string title = path->component_str(1);
    if (type != "grub")
	title = replaceBlanks (title, '_');
    int pos=getSectPos(title);
    
    if(pos>=0)
    {
	return sections[pos];
    }
    else
    {
        return NULL;
    }
}

YCPValue liloFile::Write(const YCPPath &path, const YCPValue& value, const YCPValue& pos)
{
    bool ret;
    if(path->length()==0)
    {
	if(value->isVoid())
	{
	    ret = save();
	}
	else
	{
	    ret = save(value->asString()->value_cstr());
	}
	if (!ret)
	{
	    return YCPError("Error: cannot open output file for writing");
	}
        return YCPBoolean(ret);
    }

    if (path->component_str (0) == "fromstring")
    {
	use_string = true;
	file_contents = value->asString()->value_cstr();
	parse ();
	file_contents = "";
	use_string = false;
	return YCPBoolean (true);
    }

    // set config filename
    if(path->component_str(0) == "setfilename")
    {
	fname=value->asString()->value_cstr();
        return YCPBoolean(true);
    }   


    //=========================
    // comment writing

    if(path->component_str(0)=="comment")
    {
	comment=value->asString()->value_cstr();
        return YCPBoolean(true);
    }   

    //==========================
    // sections    

    if(path->component_str(0)=="sections")
    {
	if(path->length()==1)
	{
	    return YCPError("attenpt to write to .lilo.sections", YCPBoolean(false));
	}
    
	liloSection* sect=getSectPtr(path);

	if(value->isVoid() && path->length()==2)
	{
	    //=======================
	    // remove section
	    if(sect)
	    {
		string title = path->component_str(1);
		if (type != "grub")
		    title = replaceBlanks (title, '_');
		int pos=getSectPos(title);

		vector<liloSection*>::iterator it=sections.begin();
		for(; pos>0; pos--)
		{
		    ++it;
		}

		sections.erase(it);
		return YCPBoolean(true);
	    }
	    else
	    {
		y2warning("Warning: attempt to remove non-existent section '%s'", 
		    path->component_str(1).c_str());
		return YCPBoolean(false);
	    }
	}
	if(sect==NULL)
	{
	    //====================
	    // create new section
	    sect = new liloSection(type);
	    if (sect)
	    {
		sections.push_back(sect);
		liloOption *opt = type == "grub"?
		    new liloOption("title", path->component_str(1), "") :
		    new liloOption("label", replaceBlanks (path->component_str(1), '_'), "");
		    
		sect->options->order.push_back(opt);
	    }
	    else
	    {
		return YCPError("Cannot create new section");
	    }
	}

	//=====================
	// and write some option value
	y2debug ("Adding to section");
	return sect->Write(path->at(2), value, pos);
    }

    
 
    return options.Write(path, value, pos);
}

YCPValue liloFile::Read(const YCPPath &path, const YCPValue& _UNUSED)
{
    if(path->length()==0)
    {
	// TODO: reread the file
	return YCPBoolean(true);
    }

    if (path->component_str (0) == "tostring")
    {
	use_string = true;
	file_contents = "";
	save ();
	use_string = false;
	return YCPString (file_contents);
    }

    if(path->component_str(0) == "getfilename")
    {
        return YCPString(fname);
    }

    if(path->component_str(0) == "reread")
    {
        return YCPBoolean(reread());
    }

    //=========================
    // comment reading

    if(path->component_str(0)=="comment")
    {
        return YCPString(comment);
    }

    //=========================
    // section reading    

    if(path->component_str(0)=="sections")
    {
	if(path->length()==1)
	{
	    return YCPError("section name must be specified for reading .image (eg .lilo.sections.vmlinuz)", YCPVoid());
	}
	liloSection* sect=getSectPtr(path);
	if(sect)
	{
	    return (sect->Read(path->at(2)));
	}
	return YCPVoid();
    }

    //=========================
    // option value reading    

    return options.Read(path);	
}

YCPValue liloFile::Dir(const YCPPath& path)
{
    YCPList list;
    if(path->length()>2)
    {
	return YCPVoid();
    }
    if(path->length()==0)
    {
	list=options.Dir()->asList();
	list->add(YCPString("sections"));
	return list;
    }
    if(path->length()>=1)
    {
	if(path->component_str(0) != "sections")
	{
	    return list;
	}
	if(path->length()==1)
	{
	    for(uint i=0; i<sections.size(); i++)
            {
                list->add(YCPString(sections[i]->getSectName()));
            }
            return list;
	}
	liloSection* s=getSectPtr(path);
	if(s)
	{
	    return s->Dir();   
	}
	return list;

    }
    return list;
}

void liloFile::dump(FILE* f)
{
    options.dump(f);
}

