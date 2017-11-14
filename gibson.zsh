bolt () {
    ssh -A bolt.r.cse.org.uk
}

bertha () {
    xfreerdp /v:bertha.cse.org.uk /u:tomh /d:CSE /p:$(passm -p cse.org.uk)
}
