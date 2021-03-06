#
# profiling: Line by line profiling and code coverage for GAP
#
# Implementations
#
InstallGlobalFunction( "ReadLineByLineProfile",
function(filename)
  local res, stacks;
  if IsLineByLineProfileActive() then
    Info(InfoWarning, 1, "Reading Profile while still generating it!");
  fi;
  res := READ_PROFILE_FROM_STREAM(UserHomeExpand(filename), 0);
  return res;
end );

# Merges a full list of profiles -- can run out of memory for many profiles.
BIND_GLOBAL("_prof_mergeProfiles",
function(filenames)
  local profs, f, outprof, p, line, file, line_info, line_function_calls,
  stacks, unionlist, linefunccpy, i;

  if Size(filenames) = 0 then
    ErrorNoReturn("Filenames list must be non-empty");
  fi;

  profs := [];
  # First turn all filenames into profiles
  for f in filenames do
    if IsRecord(f) then
      Add(profs, f);
    else
      Add(profs, ReadLineByLineProfile(f));
    fi;
  od;

  if not ForAll(profs, x -> x.info.is_cover = profs[1].info.is_cover) then
    ErrorNoReturn("Some profiles are covers, some are time profiles");
  fi;

  if not ForAll(profs, x -> x.info.time_type = profs[1].info.time_type) then
    ErrorNoReturn("Some profiles use wall time, some use CPU time");
  fi;

  outprof := rec();
  outprof.info := profs[1].info;

  # merge runtimes
  stacks := DictionaryBySort(true);
  for p in profs do
    for line in p.stack_runtimes do
      if KnowsDictionary(stacks, line[1]) then
        AddDictionary(stacks, line[1], LookupDictionary(stacks, line[1]) + line[2]);
      else
        AddDictionary(stacks, line[1], line[2]);
      fi;
    od;
  od;
  # Woo, internal datastructure abuse
  outprof.stack_runtimes := stacks!.entries;

  line_info := DictionaryBySort(true);
  for p in profs do
    for file in p.line_info do
      if KnowsDictionary(line_info, file[1]) then
        AddDictionary(line_info, file[1],
          file[2] + LookupDictionary(line_info, file[1]));
      else
        AddDictionary(line_info, file[1], file[2]);
      fi;
    od;
  od;
  # Woo, internal datastructure abuse
  outprof.line_info := line_info!.entries;

  line_function_calls := DictionaryBySort(true);
  for p in profs do
    for file in p.line_function_calls do

      if KnowsDictionary(line_function_calls, file[1]) then
        unionlist := [];
        linefunccpy := LookupDictionary(line_function_calls, file[1]);
        for i in [1..Maximum(Length(file[2]), Length(linefunccpy))] do
          if IsBound(file[2][i]) and IsBound(linefunccpy[i]) then
            unionlist[i] := Union(file[2][i], linefunccpy[i]);
          elif IsBound(file[2][i]) then
            unionlist[i] := Set(file[2][i]);
          else
            unionlist[i] := Set(linefunccpy[i]);
          fi;
        od;
        AddDictionary(line_function_calls, file[1], unionlist);
      else
        AddDictionary(line_function_calls, file[1], file[2]);
      fi;

    od;
  od;
  outprof.line_function_calls := line_function_calls!.entries;

  return outprof;
end );

InstallGlobalFunction( "MergeLineByLineProfiles",
function(filenames)
  local ret, prof, f;

  if Size(filenames) = 0 then
    ErrorNoReturn("Filenames list must be non-empty");
  fi;


  ret := fail;

  # Merge in pairs, else we can run out of memory.
  for f in filenames do
    if IsRecord(f) then
      prof := f;
    else
      # First turn all filenames into profiles
      prof := ReadLineByLineProfile(f);
    fi;

    if ret = fail then
      ret := prof;
    else
      ret := _prof_mergeProfiles([ret, prof]);
    fi;
  od;

  return ret;
end);

# This internal function just pretty prints a function object
_Prof_PrettyPrintFunction := function(f)
  return Concatenation(f.name, "@", f.filename, ":", String(f.line));
end;

# This just makes it easy to give dictionaries a default value 
_prof_LookupWithDefault := function(dict, val, default)
    local v;
    v := LookupDictionary(dict, val);
    if v = fail then
        return default;
    else
        return v;
    fi;
end;



# Returns a list of records containing:
# [function, time in func+children, time in func, calls]
_Prof_GatherFunctionUsage := function(data)
  local funccollection, trace, lastfunc, funcset, pos, f;

  if not(IsRecord(data)) then
    data := ReadLineByLineProfile(data);
  fi;

  funccollection := [];

  for trace in data.stack_runtimes do
    if(Length(trace[1]) > 0) then
      lastfunc := trace[1][Length(trace[1])];
      funcset := Set(trace[1]);
      for f in funcset do
        # Use the fact that [f,0,0,0] will be put in the same place as [f,x,y] for x>=0, y>=0
        pos := PositionSorted(funccollection, [f, 0, 0, 0]);
        if Length(funccollection) < pos or funccollection[pos][1] <> f then
          AddSet(funccollection, [f, 0, 0, 0]);
          pos := PositionSet(funccollection, [f, 0, 0, 0]);
        fi;
        funccollection[pos][2] := funccollection[pos][2] + trace[2];
        if f = lastfunc then
          funccollection[pos][3] := funccollection[pos][3] + trace[2];
          funccollection[pos][4] := funccollection[pos][4] + 1;
        fi;
      od;
    fi;
  od;

    return funccollection;
end;

InstallGlobalFunction("OutputFlameGraphInput",function(args...)
  local outstream, trace, fun, firstpass, data, filename, retstring;
  if Length(args) < 1 or Length(args) > 2 then
    ErrorNoReturn("Usage: OutputFlameGraph(cover[, filename])");
  fi;

  data := args[1];

  if Length(args) = 2 then
    outstream := OutputTextFile(args[2], false);
    if outstream = fail then
      ErrorNoReturn("Unable to write to file ", outstream);
    fi;
  else
    retstring := "";
    outstream := OutputTextString(retstring, false);
  fi;

  SetPrintFormattingStatus(outstream, false);

  if not(IsRecord(data)) then
    data := ReadLineByLineProfile(data);
  fi;

  for trace in data.stack_runtimes do
    firstpass := true;
    for fun in trace[1] do
      if firstpass = true then
        firstpass := false;
      else
        PrintTo(outstream, ";");
      fi;
      PrintTo(outstream, _Prof_PrettyPrintFunction(fun));
    od;
    PrintTo(outstream, " ", String(trace[2]), "\n");
  od;
  CloseStream(outstream);
  
  if IsBound(retstring) then
    return retstring;
  fi;
end);



InstallGlobalFunction("OutputFlameGraph", function(args...)
  local instr, instream, outstr, outstream;
  if Length(args) = 1 then
    instr := OutputFlameGraphInput(args[1]);
    instream := InputTextString(instr);

    outstr := "";
    outstream := OutputTextString(outstr, false);
  else
    OutputFlameGraphInput(args[1], Concatenation(args[2], ".tmp"));
    instream := InputTextFile(Concatenation(args[2], ".tmp"));

    outstream := OutputTextFile(args[2], false);
  fi;

  Process(DirectoryCurrent(), Filename(Directory("/bin"),"/sh"),
          instream, outstream,
          ["-c", Filename(DirectoriesPackageLibrary( "profiling", "FlameGraph" ),"flamegraph.pl")]);

  if Length(args) = 1 then
    return outstr;
  fi;
end);


# The CSS we want to inject into every page
_prof_CSS_std :=
"""
table { border-collapse: collapse }
tr:nth-child(odd)  { background-color: #EEE; }
tr:nth-child(even)  { background-color: #FFF; }
tr:nth-child(odd).exec  { background-color: #0F0; }
tr:nth-child(even).exec  { background-color: #3F3; }
tr:nth-child(odd).missed  { background-color: #F00; }
tr:nth-child(even).missed  { background-color: #F33; }
td, th {
    border: 1px solid #98bf21;
    padding: 3px 7px 2px 7px;
}
th {
    font-size: 1.1em;
    text-align: left;
    padding-top: 5px;
    padding-bottom: 4px;
    background-color: #A7C942;
    color: #ffffff;
}
table.sortable th:not(.sorttable_sorted):not(.sorttable_sorted_reverse):not(.sorttable_nosort):after {
    content: " \25B4\25BE"
}

/* HSV gradient made using http://www.perbang.dk/rgbgradient/ */
td.coverage00 { background-color: #FF0000; }
td.coverage10 { background-color: #F83100; }
td.coverage20 { background-color: #F25F00; }
td.coverage30 { background-color: #EB8B00; }
td.coverage40 { background-color: #E5B500; }
td.coverage50 { background-color: #DFDC00; }
td.coverage60 { background-color: #B0D800; }
td.coverage70 { background-color: #81D200; }
td.coverage80 { background-color: #55CB00; }
td.coverage90 { background-color: #2CC500; }
td.coverage100 { background-color: #04BF00; }""";

# handle the alignment of columns containing numbers
_prof_CSS_overview :=
"""
td:nth-child(2) { text-align: right; }
td:nth-child(3) { text-align: right; }
td:nth-child(4) { text-align: right; }
td:nth-child(5) { text-align: right; }
td:nth-child(6) { text-align: right; }
""";

_prof_CSS_files_withTiming :=
"""
td:nth-child(1) { text-align: right; }
td:nth-child(2) { text-align: right; }
td:nth-child(3) { text-align: right; }
td:nth-child(4) { text-align: right; }
""";

_prof_CSS_files_withoutTiming := 
"""
td:nth-child(1) { test-align: right; }
""";


# Checks if a file has correct coverage
_prof_fileHasCoverage := fileinfo -> not ForAny(fileinfo[2], x -> (x[1] = 0 and x[2] > 0));

# Checks if file has any timing attached to it
_prof_fileHasTiming := fileinfo -> ForAny(fileinfo[2], x -> (x[3] > 0));


##
InstallGlobalFunction("OutputAnnotatedCodeCoverageFiles",function(arg)
    local data, indir, outdir,
          infile, outname, instream, outstream, line, allLines,
          counter, overview, i, fileinfo, filenum, callinfo, calledbyinfo,
          readlineset, execlineset, outchar,
          outputhtml, outputoverviewhtml, outputfunctablehtml,
          stringWithSeparators,
          warnedExecNotRead, filebuf, fileview, flame;

    if Length(arg) < 2 or Length(arg) > 3 then
      ErrorNoReturn("Usage: OutputAnnotatedCodeCoverageFiles(data, [indir,] outdir)");
    fi;

    data := arg[1];
    if Length(arg) = 2 then
      indir := "";
      outdir := arg[2];
    else
      indir := arg[2];
      outdir := arg[3];
    fi;

    if IsDirectory(indir) then
      indir := indir![1];
    fi;

    if IsDirectory(outdir) then
      outdir := outdir![1];
    fi;

    indir := UserHomeExpand(indir);
    outdir := UserHomeExpand(outdir);

    # Try to make directory (might already exist)
    IO_mkdir(outdir, IO.S_IRUSR+IO.S_IWUSR+IO.S_IXUSR+
                                IO.S_IRGRP+IO.S_IXGRP+
                                IO.S_IROTH+IO.S_IXOTH);

    if IO_opendir(outdir) = fail then
      ErrorNoReturn("Unable to access directory ", outdir);
    fi;

    IO_closedir();

    if not(IsRecord(data)) then
      data := ReadLineByLineProfile(data);
    fi;

    warnedExecNotRead := false;

    # Don't bother warning about missing 'read' lines if we are just profiling
    if data.info.is_cover = false then
      warnedExecNotRead := true;
    fi;



    # IntegerToString with insertion of thousand-separators
    stringWithSeparators := function( n )
      local i, j, str, withSeps;
      str := Reversed( String(n) );
      withSeps := "";
      j := 0;
      for i in [1..Length(str)] do
        withSeps[i+j] := str[i];
        if i mod 3 = 0 and i < Length(str)  then
          withSeps[ i+j+1 ] := ',';
          j := j+1;
        fi;
      od;
      return Reversed( withSeps );
    end;

    outputfunctablehtml := function(outstream)
      local funcusage, line, fn, linkname,name;

      funcusage := _Prof_GatherFunctionUsage(data);
      PrintTo(outstream, "<!DOCTYPE html><script src=\"sorttable.js\"></script><html><body>\n");
      PrintTo(outstream, "<style>");
      PrintTo(outstream, _prof_CSS_std);
      PrintTo(outstream,"</style>");
      PrintTo(outstream, "<table class=\"sortable\">\n");

      PrintTo(outstream, "<thead>");
      PrintTo(outstream, "<tr>");
      PrintTo(outstream, "<th>Func</th><th>Execs</th><th>Time</th><th>Time+Childs</th>\n");
      PrintTo(outstream, "</tr>");
      PrintTo(outstream, "</thead>\n");
      
      PrintTo(outstream, "<tbody>\n");
      for line in funcusage do
        fn := line[1];
        PrintTo(outstream, "<tr><td>");
        linkname := ReplacedString(fn.filename, "/", "_");
        Append(linkname, ".html");
        name := fn.name;
        if name = "nameless" then
          name := Concatenation(fn.filename, ":", String(fn.line));
        fi;
        PrintTo(outstream, "<a href=\"",linkname,"#line",String(fn.line),"\">",name,"</a> ");
        PrintTo(outstream, "</td><td>",line[4], "</td><td>", line[3], "</td><td>", line[2], "</td></tr>\n");
      od;
      PrintTo(outstream, "</tbody></table></body></html>\n");
    end;

    outputhtml := function(lines, fileinfo, subfunctions, calledbyfunctions, outfilestream)
      local i, outchar, time, calls, calledfns, linkname, fn, name, filebuf, coverage, hasTiming, hasCoverage, funcs, outstream, outstring;
      outstring := "";
      outstream := OutputTextString(outstring, false);
      SetPrintFormattingStatus(outstream, false);

      hasTiming := _prof_fileHasTiming(fileinfo);
      hasCoverage := _prof_fileHasCoverage(fileinfo);
      coverage := fileinfo[2];
      PrintTo(outstream, "<!DOCTYPE html><script src=\"sorttable.js\"></script><html><body>\n");
      PrintTo(outstream, "<style>");
      PrintTo(outstream, _prof_CSS_std);
      if hasTiming then
        PrintTo(outstream, _prof_CSS_files_withTiming);
      else
        PrintTo(outstream, _prof_CSS_files_withoutTiming);
      fi;
      PrintTo(outstream, "</style>");

      if not hasCoverage then
        PrintTo(outstream, "<p>This file was read by GAP before profiling was actived, so lines which were not read but not executed are not marked.</p>");
      fi;


      PrintTo(outstream, "<table class=\"sortable\">\n");

      PrintTo(outstream, "<thead>");
      PrintTo(outstream, "<tr>");
      if hasTiming then
        PrintTo(outstream, "<th>Line</th><th>Execs</th><th>Time</th><th>Time+Childs</th><th>Code</th><th>Called Functions</th><th>Called From</th>\n");
      else
        PrintTo(outstream, "<th>Line</th><th>Code</th>\n");
      fi;
      PrintTo(outstream, "</tr>");
      PrintTo(outstream, "</thead>\n");
      
      PrintTo(outstream, "<tbody>\n");
      for i in [1..Length(lines)] do

        if not(IsBound(coverage[i])) or (coverage[i] = [0,0,0,0]) then
          outchar := "ignore";
        elif coverage[i][2] >= 1 then
          outchar := "exec";
        elif coverage[i][1] >= 1 then
          outchar := "missed";
        else
          Error("Invalid profile - there were lines which were not executed, but took time!");
        fi;

        # Print start of page
        PrintTo(outstream, "<tr class='", outchar,"'>");
        PrintTo(outstream, "<td><a name=\"line",i,"\"></a>",i,"</td>");

        if hasTiming then
            time := "<td></td><td></td><td></td>";
            if IsBound(coverage[i]) and coverage[i][2] >= 1 then
              calls := coverage[i][2];
              if data.info.is_cover and calls > 1 then
                calls := 0;
              fi;

              if coverage[i][3] >= 1 or coverage[i][4] >= 1 then
                time := Concatenation("<td>",stringWithSeparators(calls),
                                      "</td><td>",
                                      stringWithSeparators(coverage[i][3]),
                                      "</td><td>",
                                      stringWithSeparators(coverage[i][4]+coverage[i][3]),
                                      "</td>");
              else
                time := Concatenation("<td>",stringWithSeparators(calls),
                                      "</td><td></td><td></td>");
              fi;
            fi;

            PrintTo(outstream, time);

        fi;
        
        PrintTo(outstream, "<td><span><tt>", HTMLEncodeString(lines[i]), "</tt></span></td>");

        if hasTiming then
            # totaltime := LookupWithDefault(linedict.recursetime, i, "");

            calledfns := "";
            if Length(subfunctions) >= i then
              for fn in subfunctions[i] do
                linkname := ReplacedString(fn.filename, "/", "_");
                Append(linkname, ".html");
                name := fn.name;
                if name = "nameless" then
                  name := Concatenation(fn.filename, ":", String(fn.line));
                fi;
                Append(calledfns, Concatenation("<a href=\"",linkname,"#line",String(fn.line),"\">",name,"</a> "));
              od;
            fi;
            PrintTo(outstream, "<td><span>",calledfns,"</span></td>");

            calledfns := "";
            if Length(calledbyfunctions) >= i then
              for fn in calledbyfunctions[i] do
                linkname := ReplacedString(fn.filename, "/", "_");
                Append(linkname, ".html");
                name := Concatenation(fn.filename, ":", String(fn.line));
                Append(calledfns, Concatenation("<a href=\"",linkname,"#line",String(fn.line),"\">",name,"</a> "));
              od;
            fi;
            PrintTo(outstream, "<td><span>",calledfns,"</span></td>");
        fi;
        PrintTo(outstream, "</tr>\n");
      od;

      PrintTo(outstream, "</tbody>\n");
      PrintTo(outstream, "</table></body></html>\n");

      CloseStream(outstream);
      PrintTo(outfilestream, outstring);
    end;

    outputoverviewhtml := function(overview, outdir, havetime)
      local filename, outstream, codecover, i, any_timeexec;

      Sort(overview, function(v,w) return v.inname < w.inname; end);

      any_timeexec := ForAny(overview, i -> IsBound(i.filetime) and IsBound(i.fileexec) );
      
      filename := Concatenation(outdir, "/index.html");
      outstream := OutputTextFile(filename, false);
      SetPrintFormattingStatus(outstream, false);
      PrintTo(outstream, "<!DOCTYPE html><script src=\"sorttable.js\"></script><html><body>\n");
      PrintTo(outstream, "<style>");
      PrintTo(outstream, Concatenation(_prof_CSS_std, _prof_CSS_overview));
      PrintTo(outstream, "</style>");
      if havetime then
        PrintTo(outstream, """<p><a href="flame.svg">Flame Graph</a></p>""");
        PrintTo(outstream, """<p><a href="funcoverview.html">Function Overview</a></p>""");
      fi;
      PrintTo(outstream, "<table cellspacing='0' cellpadding='0' class=\"sortable\">\n",
        "<thead><tr><th>File</th><th>Coverage%</th><th>Executed Lines</th><th>Total Lines</th>");
      if any_timeexec then
        PrintTo(outstream, "<th>Time</th><th>Statements</th>");
      fi;
      PrintTo(outstream, "</tr></thead>\n");

      PrintTo(outstream, "<tbody>\n");
      for i in overview do
        PrintTo(outstream, "<tr>");
        PrintTo(outstream, "<td><a href='",
           Remove(SplitString(i.outname,"/")),
           "'>",i.inname,"</a></td>");

        if IsBound(i.execlines) and IsBound(i.readnotexeclines) then
            codecover := 1 - (i.readnotexeclines / (i.execlines + i.readnotexeclines));
            PrintTo(outstream, "<td class='coverage",Int(codecover*10),"0'>",Int(codecover*100),"</td>");
        else
            PrintTo(outstream, "<td>N/A</td>");
        fi;

        PrintTo(outstream, "<td>", stringWithSeparators(i.execlines), "</td>");
        if IsBound(i.readnotexeclines) then
            PrintTo(outstream, "<td>",
                    stringWithSeparators(i.execlines + i.readnotexeclines), "</td>");
        else
            PrintTo(outstream, "<td>?</td>");
        fi;

        if any_timeexec then
          if IsBound(i.filetime) and IsBound(i.fileexec) then
              PrintTo(outstream, "<td>",
                      stringWithSeparators(i.filetime), "</td><td>",
                      stringWithSeparators(i.fileexec), "</td>");
          else
              PrintTo(outstream, "<td>N/A</td><td>N/A</td>");
          fi;
        fi;
        PrintTo(outstream, "</tr>\n");
      od;

      PrintTo(outstream, "</tbody>\n");
      PrintTo(outstream, "</table></body></html>\n");
      CloseStream(outstream);
    end;

    overview := [];
    for filenum in [1..Length(data.line_info)] do
        fileinfo := data.line_info[filenum];
        callinfo := data.line_function_calls[filenum];
        calledbyinfo := data.line_calling_function_calls[filenum];
        infile := fileinfo[1];
        if Length(indir) <= Length(infile)
                and indir = infile{[1..Length(indir)]} then
            # Make a nicer output filename, handling the input being in
            # directories, or having *s in the name.
            outname := infile;
            outname := ReplacedString(outname, "/", "_");
            outname := ReplacedString(outname, "*", "_");
            outname := Concatenation(outdir, "/", outname);
            outname := Concatenation(outname, ".html");
            outstream := OutputTextFile(outname, false);
            SetPrintFormattingStatus(outstream, false);

            # Check file exists. This also handles us accidentally trying
            # to open files like *stdin*
            if IsExistingFile(infile) then
              instream := InputTextFile(infile);
              allLines := [];
              line := ReadLine(instream);
              while line <> fail do
                Add(allLines, line);
                line := ReadLine(instream);
              od;
              CloseStream(instream);
            else
              allLines := List([1..Length(fileinfo[2])], x -> "<missing file>");
            fi;

            # Check for lines which are executed, but not read

            if ForAny(fileinfo[2], x -> (x[1] = 0 and x[2] > 0) and not warnedExecNotRead) then
              Print("# Warning: Some lines marked executed but not read. If you\n",
                    "# want to see which lines are NOT executed,\n",
                    "# use the --prof/--cover command line options\n");
              warnedExecNotRead := true;
            fi;

            fileview := rec(outname := outname,
                            inname := infile,
                            execlines := Length(Filtered(fileinfo[2], x -> (x[2] >= 1))));

            if _prof_fileHasTiming(fileinfo) then
                fileview.fileexec := Sum(fileinfo[2], x -> x[2]);
                fileview.filetime := Sum(fileinfo[2], x -> x[3]);
            fi;

            if _prof_fileHasCoverage(fileinfo) then
                fileview.readnotexeclines := Length(Filtered(fileinfo[2], x -> (x[1] >= 1 and x[2] = 0)));
            fi;
            
            Add(overview, fileview);

            outputhtml(allLines, fileinfo, callinfo[2], calledbyinfo[2], outstream);

            CloseStream(outstream);
        fi;
    od;

    # Just copy the file 'sorttable.js'
    filebuf := ReadAll(InputTextFile(Filename(DirectoriesPackageLibrary( "profiling", "data"), "sorttable.js")));
    outstream := OutputTextFile(Concatenation(outdir, "/sorttable.js"), false);
    SetPrintFormattingStatus(outstream, false);
    PrintTo(outstream, filebuf);
    CloseStream(outstream);


    if ForAny(overview, x -> IsBound(x.filetime) and x.filetime > 0) then
      OutputFlameGraph(data, Concatenation(outdir, "/flame.svg"));

      outstream := OutputTextFile(Concatenation(outdir, "/funcoverview.html"), false);
      SetPrintFormattingStatus(outstream, false);
      outputfunctablehtml(outstream);
      CloseStream(outstream);

      outputoverviewhtml(overview, outdir, true);
    else
      outputoverviewhtml(overview, outdir, false);
    fi;
end);

InstallGlobalFunction(OutputJsonCoverage,
function(data, outfile)
    local outstream, lineinfo, prev, file, lines;

    outfile := UserHomeExpand(outfile);
    outstream := IO_File(outfile, "w");

    if not(IsRecord(data)) then
      data := ReadLineByLineProfile(data);
    fi;

    lineinfo := function(lineno, stat)
        if stat[1] > 0 then
            if stat[2] > 0 then
                return STRINGIFY("\"", lineno, "\": \"1\"");
            else
                return STRINGIFY("\"", lineno, "\": \"0\"");
            fi;
        fi;
        return "";
    end;

    IO_Write(outstream, "{ \"coverage\": {\n");
    prev := false;

    for file in data.line_info do
        if file[1] <> "stream" then
            if prev then
                IO_Write(outstream, ",\n");
            fi;
            IO_Write(outstream, Concatenation("\"", file[1], "\": {\n" ));
            lines := List([1..Length(file[2])], n -> lineinfo(n, file[2][n]));
            lines := Filtered(lines, l -> Length(l) > 0);
            IO_Write(outstream, JoinStringsWithSeparator(lines, ",\n"));
            IO_Write(outstream, "}\n");
            prev := true;
        fi;
    od;
    IO_Write(outstream, "} }");
    IO_Close(outstream);
end);

InstallGlobalFunction("LineByLineProfileFunction",
  function(f, args)
    local dir;
    if IsLineByLineProfileActive() then
      ErrorNoReturn("Cannot profile when profiling already active!");
    fi;
    dir := DirectoryTemporary();
    ProfileLineByLine(Filename(dir, "/prof.gz"));
    CallFuncList(f, args);
    UnprofileLineByLine();
    OutputAnnotatedCodeCoverageFiles(Filename(dir, "/prof.gz"),
                                     Filename(dir, "/output"));
    if ARCH_IS_MAC_OS_X() then
      Exec(Concatenation("open ",Filename(dir, "/output/index.html")));
    elif ARCH_IS_WINDOWS() then
      Exec(Concatenation("cmd /c start ",Filename(dir, "/output/index.html")));
    else
      Exec(Concatenation("xdg-open ",Filename(dir, "/output/index.html")));
    fi;
  end);

